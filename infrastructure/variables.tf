variable "aws_region" {
  description = "AWS region (the account's Free plan only allows eu-north-1)"
  type        = string
  default     = "eu-north-1"
}

variable "project" {
  description = "Short name used as a prefix in resource names"
  type        = string
  default     = "lms"
}

variable "environment" {
  description = "Environment name; this stack is the AWS staging copy"
  type        = string
  default     = "staging"
}

# ---- Network ----

variable "vpc_cidr" {
  description = "Address range of the LMS VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "nat_per_az" {
  description = "One NAT gateway per zone (no single point of failure for outbound traffic) instead of one in zone A; each costs ~$1.1/day plus data"
  type        = bool
  default     = false
}

variable "availability_zones" {
  description = "Zones to spread subnets and tasks across (Stockholm has a, b and c)"
  type        = list(string)
  default     = ["eu-north-1a", "eu-north-1b", "eu-north-1c"]
}

# ---- App ----

# One ECS service per API, mirroring the VPS (one process per port behind
# the proxy). Every service runs the same image and the full Django app;
# the load balancer only decides which one handles a path.
variable "api_services" {
  description = "API name => container port and the URL paths routed to it (max 5 paths each)"
  type = map(object({
    port  = number
    paths = list(string)
  }))
  default = {
    curriculum_api = { port = 8001, paths = ["/curriculum_api/*"] }
    coach_api      = { port = 8002, paths = ["/coach_api/*"] }
    quiz_api       = { port = 8003, paths = ["/quiz_api/*"] }
    learner_api    = { port = 8004, paths = ["/learner_api/*"] }
    engagement_api = { port = 8005, paths = ["/engagement_api/*"] }
    audit_api      = { port = 8006, paths = ["/audit_api/*"] }
    chat           = { port = 8007, paths = ["/ws/*", "/api/chat/*"] }
    enrolment_api  = { port = 8008, paths = ["/enrolment_api/*"] }
    login_api      = { port = 8009, paths = ["/login_api/*"] }
  }
}

# URL prefixes CloudFront sends to the load balancer (Django); everything
# else is the React app from S3. Same list as the dev proxy in
# frontend/vite.config.ts, plus the Django admin.
variable "backend_paths" {
  description = "CloudFront path patterns served by the backend"
  type        = list(string)
  default = [
    "/api/*",
    "/ws/*",
    "/curriculum_api/*",
    "/coach_api/*",
    "/quiz_api/*",
    "/learner_api/*",
    "/engagement_api/*",
    "/audit_api/*",
    "/hours_test_api/*",
    "/manual_audit_api/*",
    "/enrolment_api/*",
    "/login_api/*",
    "/progress_reviews_api/*",
    "/django_admin/*",
  ]
}

variable "disabled_services" {
  description = "APIs from api_services not deployed for now (no ECS service, target group or routing rule); their paths fall through to default_service, which runs the same Django app"
  type        = list(string)
  default     = ["chat", "audit_api"]

  validation {
    condition     = !contains(var.disabled_services, var.default_service)
    error_message = "default_service must stay enabled: it receives the disabled services' paths."
  }
}

variable "default_service" {
  description = "Service that receives every path not listed in api_services"
  type        = string
  default     = "curriculum_api"
}

variable "task_cpu" {
  description = "Fargate CPU units per task (1024 = 1 vCPU)"
  type        = number
  default     = 1024
}

variable "task_memory" {
  description = "Fargate memory per task in MiB (1 vCPU allows 2048-8192)"
  type        = number
  default     = 2048
}

variable "image_tag" {
  description = "Tag of the backend image in ECR that every service runs"
  type        = string
  default     = "staging"
}

variable "desired_count" {
  description = "Running tasks per API service (0 = stop all services to save cost)"
  type        = number
  default     = 1
}

variable "web_workers" {
  description = "Uvicorn worker processes per container (WEB_CONCURRENCY); each uses ~150-250 MB"
  type        = number
  default     = 3
}

variable "max_count" {
  description = "Most tasks auto scaling may run per API service (unless service_max_counts says otherwise)"
  type        = number
  default     = 4
}

variable "service_max_counts" {
  description = "Services that may scale beyond max_count (api name => most tasks). Tasks above the minimum run on Fargate Spot, so together they stay within the account's 12 On-Demand + 12 Spot vCPU"
  type        = map(number)
  default     = {}
}

variable "spot_scale_out" {
  description = "Tasks above each service's minimum run on Fargate Spot (separate 12 vCPU limit, ~70% cheaper, may be stopped with 2 minutes' notice and replaced)"
  type        = bool
  default     = false
}

variable "burst_scale_out" {
  description = "Add the burst step-scaling rule (burst_step tasks at once above burst_cpu_threshold) on top of target tracking"
  type        = bool
  default     = false
}

variable "burst_cpu_threshold" {
  description = "Average CPU % at which a service adds burst_step tasks at once (on top of target tracking), so a sudden surge doesn't wait ~3 minutes"
  type        = number
  default     = 75
}

variable "burst_step" {
  description = "Tasks added at once when CPU passes burst_cpu_threshold"
  type        = number
  default     = 3
}

variable "service_sizes" {
  description = "Services that run smaller than task_cpu/task_memory/web_workers (api name => size); quiet services, to stay under the account's 12 vCPU Fargate limit"
  type = map(object({
    cpu     = number
    memory  = number
    workers = number
  }))
  default = {
    chat      = { cpu = 256, memory = 1024, workers = 1 }
    audit_api = { cpu = 512, memory = 1024, workers = 2 }
  }
}

variable "service_min_counts" {
  description = "Services that always run more than desired_count tasks (api name => minimum); the busiest APIs, so a spike doesn't wait for auto scaling"
  type        = map(number)
  default = {
    login_api      = 2
    learner_api    = 2
    curriculum_api = 2
    enrolment_api  = 2
  }
}

variable "cpu_target" {
  description = "Average CPU % per service that auto scaling keeps tasks at"
  type        = number
  default     = 60
}

variable "domain_name" {
  description = "Custom domain of this environment (CNAME at Hostinger -> CloudFront); never the production lms. domain"
  type        = string
  default     = "lms-aws.kentbusinesscollege.net"
}

variable "certificate_domain" {
  description = "Existing ISSUED certificate in us-east-1 that covers domain_name"
  type        = string
  default     = "*.kentbusinesscollege.net"
}

variable "app_hosts" {
  description = "Extra public host names the site is served on, besides CloudFront's and domain_name"
  type        = list(string)
  default     = []
}

# Values live only in secrets.auto.tfvars (git-ignored), generated from backend/.env
variable "app_secrets" {
  description = "App settings from backend/.env (name => value), stored in Secrets Manager"
  type        = map(string)
  sensitive   = true
  default     = {}
}

variable "app_secrets_version" {
  description = "Changes when app_secrets change (set by scripts/env_to_tfvars.py), to send the new values to AWS"
  type        = number
  default     = 1
}

variable "lb_algorithm" {
  description = "How the load balancer picks a task: round_robin, or least_outstanding_requests (sends each request to the task with the fewest in progress; much better at 2000+ users)"
  type        = string
  default     = "round_robin"
}

variable "health_check_path" {
  description = "Path the load balancer polls on each task; must return 200 without host validation"
  type        = string
  default     = "/health/"
}

# ---- Valkey (ElastiCache) ----

variable "valkey_engine_version" {
  description = "Valkey major.minor version"
  type        = string
  default     = "8.1"
}

variable "valkey_node_type" {
  description = "Size of each Valkey node"
  type        = string
  default     = "cache.t4g.micro"
}
