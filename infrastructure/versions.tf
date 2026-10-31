# ------------------------------------------------------------
# LMS on AWS - Terraform and provider setup
# Region: eu-north-1 (Stockholm). The architecture diagram shows London,
# but the AWS account's Free plan only allows eu-north-1.
# ------------------------------------------------------------

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State is local (infrastructure/terraform.tfstate, git-ignored).
  # Move it to an S3 backend before more than one person runs Terraform.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# CloudFront only accepts certificates from us-east-1, so certificate
# lookups use this second provider. Nothing else is created there.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
