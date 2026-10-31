# ------------------------------------------------------------
# Auto scaling: each API service adds tasks when its average CPU stays
# above var.cpu_target and removes them when it falls again.
# Range: var.desired_count (or its service_min_counts entry) .. var.max_count
# (or its service_max_counts entry) tasks. desired_count = 0 still
# stops everything (min and max both become 0).
# ------------------------------------------------------------

resource "aws_appautoscaling_target" "api" {
  for_each = local.api_services

  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api[each.key].name}"
  min_capacity       = local.min_tasks[each.key]
  max_capacity       = var.desired_count == 0 ? 0 : max(lookup(var.service_max_counts, each.key, var.max_count), local.min_tasks[each.key])
}

locals {
  # desired_count, raised for the services in service_min_counts; 0 stops all
  min_tasks = {
    for k, v in local.api_services :
    k => var.desired_count == 0 ? 0 : max(var.desired_count, lookup(var.service_min_counts, k, 0))
  }
}

resource "aws_appautoscaling_policy" "api_cpu" {
  for_each = local.api_services

  name               = "${local.name}-${replace(each.key, "_", "-")}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api[each.key].service_namespace
  scalable_dimension = aws_appautoscaling_target.api[each.key].scalable_dimension
  resource_id        = aws_appautoscaling_target.api[each.key].resource_id

  target_tracking_scaling_policy_configuration {
    target_value = var.cpu_target

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    scale_out_cooldown = 60  # add tasks quickly under load
    scale_in_cooldown  = 300 # remove them slowly, so short dips don't cause flapping
  }
}

# Burst (var.burst_scale_out): target tracking needs ~3 minutes of high CPU before it adds tasks.
# When a service's CPU passes burst_cpu_threshold for one minute, add
# burst_step tasks at once; App Auto Scaling uses whichever policy asks for
# more. Scale-in is left to target tracking.
resource "aws_appautoscaling_policy" "api_burst" {
  for_each = var.burst_scale_out ? local.api_services : {}

  name               = "${local.name}-${replace(each.key, "_", "-")}-burst"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.api[each.key].service_namespace
  scalable_dimension = aws_appautoscaling_target.api[each.key].scalable_dimension
  resource_id        = aws_appautoscaling_target.api[each.key].resource_id

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = var.burst_step
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "api_burst" {
  for_each = var.burst_scale_out ? local.api_services : {}

  alarm_name          = "${local.name}-${replace(each.key, "_", "-")}-cpu-burst"
  alarm_description   = "CPU above ${var.burst_cpu_threshold}% for a minute: add ${var.burst_step} tasks"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.burst_cpu_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.api[each.key].name
  }

  alarm_actions = [aws_appautoscaling_policy.api_burst[each.key].arn]
}
