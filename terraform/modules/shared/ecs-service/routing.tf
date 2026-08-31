# Public routing, created only for services that need a public identity. Every
# service has one today. A null hostname leaves the service reachable over the
# private namespace alone.

resource "aws_lb_target_group" "this" {
  count = var.hostname == null ? 0 : 1

  name        = substr(local.name, 0, 32)
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    # Services disagree: /health for sprue, hilt and swarf, /healthcheck for the
    # delegator and signing service, /_health for plc.
    path                = var.health_check_path
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Long enough to finish an in-flight request, short enough that a deploy does
  # not stall. Swarf's SSE streams are cut at this point rather than held.
  deregistration_delay = 30

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_rule" "this" {
  count = var.hostname == null ? 0 : 1

  listener_arn = var.listener_arn
  priority     = var.listener_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }

  condition {
    host_header {
      values = [var.hostname]
    }
  }
}

resource "aws_route53_record" "this" {
  count = var.hostname == null ? 0 : 1

  zone_id = var.route53_zone_id
  name    = var.hostname
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# Private DNS for callers inside the VPC. hilt reaches OpenBao this way, and
# sprue, hilt and swarf reach plc this way rather than out through the NAT
# gateway and back in at the ALB.
resource "aws_service_discovery_service" "this" {
  count = var.register_internal ? 1 : 0

  name = var.service

  # ECS registers the running task as an instance here, and Cloud Map refuses
  # to delete a service that still holds one. Replacing this resource therefore
  # deadlocks against the task it serves: the registration only moves once the
  # ECS service is updated, which Terraform does after the delete. This lets
  # the provider clear the instances itself.
  force_destroy = true

  dns_config {
    namespace_id = var.namespace_id

    dns_records {
      type = "A"
      ttl  = 10
    }

    routing_policy = "MULTIVALUE"
  }

  # Required for ECS to report task health for the registered instance, and it
  # cannot be added to an existing service, so dropping it would mean replacing
  # this service to get it back. `health_check_config`, which the provider
  # recommends instead, serves public namespaces only; this one is private.
  #
  # failure_threshold is deprecated and AWS always applies 1, so the value here
  # is inert. It is stated anyway because an empty block is not sent at all:
  # CreateService then records no custom health config, the next read finds
  # none where the configuration declares one, and every plan schedules another
  # replacement that lands in the same state. The deprecation warning is the
  # price of a service that stops being recreated on every apply.
  #
  # The deprecation comes from AWS: Cloud Map fixed the custom health check
  # wait at one 30-second interval and deprecated FailureThreshold in the API,
  # and provider v6.0.0 mirrored that, promising removal in the next major
  # version. Until the provider stops warning on the value AWS forces anyway
  # (https://github.com/hashicorp/terraform-provider-aws/issues/44285) or lets
  # the argument go without replacing the service
  # (https://github.com/hashicorp/terraform-provider-aws/pull/43428), the
  # warning stays. The deprecation itself is documented per
  # https://github.com/hashicorp/terraform-provider-aws/issues/44291.
  health_check_custom_config {
    failure_threshold = 1
  }
}
