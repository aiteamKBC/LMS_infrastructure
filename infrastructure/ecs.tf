# ------------------------------------------------------------
# ECS cluster (diagram: "ECS Fargate - API, chat, workers")
# One task definition + service per enabled API (local.api_services), all running the
# same image on their own port, like the processes behind the VPS proxy.
# ------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"

  # Per-task CPU/memory/network metrics in CloudWatch (diagram: "CloudWatch - logs, metrics")
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# On-Demand and Spot pools: each has its own 12 vCPU account limit
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

locals {
  # The APIs actually deployed: api_services minus disabled_services
  api_services = { for k, v in var.api_services : k => v if !contains(var.disabled_services, k) }

  # Domains users open the site on: the custom domain, CloudFront's own, and any extras
  site_hosts = concat([var.domain_name, aws_cloudfront_distribution.main.domain_name], var.app_hosts)
  site_url   = "https://${var.domain_name}"

  app_image  = "${aws_ecr_repository.backend.repository_url}:${var.image_tag}"
  valkey_url = "rediss://${aws_elasticache_replication_group.valkey.primary_endpoint_address}:6379" # rediss = TLS

  # Plain (non-secret) settings, the same for every service. These take the
  # place of the same names in backend/.env (they are left out of the secret).
  app_environment = {
    DJANGO_DEBUG = "false"

    # Changes when app_secrets_version is raised, so every service restarts
    # and reads the new secret values
    APP_SECRETS_VERSION = tostring(var.app_secrets_version)

    # Worker processes per container, so a task can use its whole vCPU
    WEB_CONCURRENCY = tostring(var.web_workers)

    # CloudFront forwards the browser's Host (the site's domain); the load
    # balancer name is kept for direct checks
    DJANGO_ALLOWED_HOSTS = join(",", concat([aws_lb.main.dns_name], local.site_hosts))
    CSRF_TRUSTED_ORIGINS = join(",", [for h in local.site_hosts : "https://${h}"])

    # Valkey: cache in DB 0, chat (Channels) messages in DB 1
    CACHE_URL                            = "${local.valkey_url}/0"
    CHAT_REDIS_URL                       = "${local.valkey_url}/1"
    REDIS_URL                            = "${local.valkey_url}/0" # fallback name some code reads
    CACHE_KEY_PREFIX                     = local.name
    CACHE_SOCKET_CONNECT_TIMEOUT_SECONDS = "1" # TLS handshake needs more than the 0.2s local default
    CACHE_SOCKET_TIMEOUT_SECONDS         = "1"

    # backend/.env is a development file (localhost URLs). Sign-in redirects
    # and links in emails must come back to this site instead. Each callback
    # must also be listed as a redirect URI in its Microsoft/Google app.
    FRONTEND_URL                 = local.site_url
    MICROSOFT_SSO_CALLBACK_URI   = "${local.site_url}/login_api/microsoft/callback/"
    AZURE_LOGIN_APP_REDIRECT_URI = "${local.site_url}/api/auth/azure/callback"
    MICROSOFT_CALLBACK_URI       = "${local.site_url}/api/calendar/microsoft/callback"
    GOOGLE_CALLBACK_URI          = "${local.site_url}/api/calendar/google/callback"

    # Background schedulers off: the VPS already runs them against the same
    # databases, so running them here too would send duplicate emails and syncs
    SESSION_RESULTS_AUTOMATIC         = "false"
    COACH_DASHBOARD_SNAPSHOT_SCHEDULE = "false"
    CATCHUP_REMINDERS_ENABLED         = "false"
    CHAT_DEMO_BOOTSTRAP_ENABLED       = "false"
  }

  # Every key of the secret except those set above (key names aren't secret).
  # Only real variable names: anything else would be a piece of a value.
  app_secret_keys = sort([
    for k in setsubtract(nonsensitive(keys(var.app_secrets)), concat(keys(local.app_environment), ["PORT"])) :
    k if can(regex("^[A-Za-z_][A-Za-z0-9_-]*$", k))
  ])
}

resource "aws_ecs_task_definition" "api" {
  for_each = local.api_services

  family                   = "${local.name}-${replace(each.key, "_", "-")}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = try(var.service_sizes[each.key].cpu, var.task_cpu)
  memory                   = try(var.service_sizes[each.key].memory, var.task_memory)
  execution_role_arn       = aws_iam_role.task_execution.arn # pulls the image, reads the secret, writes logs
  task_role_arn            = aws_iam_role.task.arn           # what the app itself may call (SQS, X-Ray)

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # the image is built for linux/amd64
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = local.app_image
    essential = true

    portMappings = [{ containerPort = each.value.port, protocol = "tcp" }]

    environment = [
      for k, v in merge(local.app_environment, {
        PORT            = tostring(each.value.port)
        WEB_CONCURRENCY = tostring(try(var.service_sizes[each.key].workers, var.web_workers))
      }) :
      { name = k, value = v }
    ]

    # Each key of the JSON secret becomes an environment variable
    secrets = [
      for k in local.app_secret_keys :
      { name = k, valueFrom = "${aws_secretsmanager_secret.app.arn}:${k}::" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = replace(each.key, "_", "-")
      }
    }

    # Time for open requests/WebSockets to finish after ECS asks Daphne to stop
    stopTimeout = 60
  }])
}

resource "aws_ecs_service" "api" {
  for_each = local.api_services

  name            = replace(each.key, "_", "-")
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api[each.key].arn
  desired_count   = var.desired_count

  # The minimum tasks run On-Demand; tasks auto scaling adds above it run on
  # Spot (var.spot_scale_out), which has its own 12 vCPU limit
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = local.min_tasks[each.key]
    weight            = var.spot_scale_out ? 0 : 1
  }
  dynamic "capacity_provider_strategy" {
    for_each = var.spot_scale_out ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = 1
    }
  }
  force_new_deployment = true # needed to change the strategy of a running service

  # Tasks run in the private app subnets of all 3 zones, with no public IP
  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api[each.key].arn
    container_name   = "app"
    container_port   = each.value.port
  }

  # Django needs time to start before the first health check counts
  health_check_grace_period_seconds = 120

  # Rolling update: start the new task before stopping the old one, and roll
  # back automatically if the new version never becomes healthy
  # Services with 2+ tasks replace one task at a time (stop one, start one),
  # so a rollout needs no spare vCPU under the account's 12 vCPU Fargate
  # limit. Single-task services start the new task first (needs 1 spare task).
  deployment_minimum_healthy_percent = local.min_tasks[each.key] >= 2 ? 50 : 100
  deployment_maximum_percent         = local.min_tasks[each.key] >= 2 ? 100 : 200
  # AZ rebalancing requires maximum_percent above 100
  availability_zone_rebalancing = local.min_tasks[each.key] >= 2 ? "DISABLED" : "ENABLED"
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  propagate_tags = "SERVICE"

  # Auto scaling (autoscaling.tf) owns the running count after creation;
  # desired_count reaches it through min_capacity instead
  lifecycle {
    ignore_changes = [desired_count]
  }

  # The target group must be attached to the listener, and the secret must
  # have values, before tasks start
  depends_on = [aws_lb_listener.http, aws_lb_listener_rule.api, aws_secretsmanager_secret_version.app, aws_ecs_cluster_capacity_providers.main]
}
