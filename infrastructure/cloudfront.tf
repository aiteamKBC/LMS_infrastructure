# ------------------------------------------------------------
# CloudFront (diagram: "CloudFront - HTTPS entry point")
# One domain for the whole site, like the VPS proxy:
#   var.backend_paths (API, chat WebSocket, admin) -> load balancer
#   everything else                                -> React app in S3
# The frontend calls the API with relative paths, so no CORS is needed.
# ------------------------------------------------------------

# AWS-managed policies
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

# Forwards every header (incl. Host and the WebSocket upgrade), cookie and
# query string, so Django sees the request as the browser sent it
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

# The existing wildcard certificate (also used by the image uploader)
data "aws_acm_certificate" "site" {
  provider    = aws.us_east_1
  domain      = var.certificate_domain
  statuses    = ["ISSUED"]
  most_recent = true
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.name}-frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# React routes (/learner/home, ...) have no file in S3: serve index.html and
# let the app's router handle them. Only runs for S3, so API 404s stay intact.
resource "aws_cloudfront_function" "spa_routes" {
  name    = "${local.name}-spa-routes"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var lastSegment = request.uri.split('/').pop();
      if (lastSegment.indexOf('.') === -1) {
        request.uri = '/index.html';
      }
      return request;
    }
  EOT
}

locals {
  s3_origin_id  = "frontend-s3"
  alb_origin_id = "backend-alb"
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  comment             = "${local.name} - LMS frontend + API"
  default_root_object = "index.html"
  aliases             = [var.domain_name]
  price_class         = "PriceClass_100" # edge locations in Europe and North America
  http_version        = "http2and3"

  origin {
    origin_id                = local.s3_origin_id
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  origin {
    origin_id   = local.alb_origin_id
    domain_name = aws_lb.main.dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # the load balancer has no certificate yet
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 60
    }
  }

  # Everything not matched below: the React app
  default_cache_behavior {
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_routes.arn
    }
  }

  # Backend paths: never cached, everything forwarded
  dynamic "ordered_cache_behavior" {
    for_each = var.backend_paths
    content {
      path_pattern             = ordered_cache_behavior.value
      target_origin_id         = local.alb_origin_id
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
      compress                 = true
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # https://<domain_name>; the https://<id>.cloudfront.net address keeps working too
  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.site.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}
