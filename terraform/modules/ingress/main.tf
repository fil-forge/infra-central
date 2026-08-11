# One ALB for the whole stage, with host-based routing to each service.
#
# Public hostnames are not cosmetic here. Services identify each other by
# did:web, which resolves by fetching https://<host>/.well-known/did.json, so
# every service that other services authenticate must be reachable at a real
# name with a real certificate.

locals {
  name = "forge-${var.stage}"
}

data "aws_route53_zone" "this" {
  name         = var.zone_name
  private_zone = false
}

resource "aws_lb" "this" {
  name               = local.name
  load_balancer_type = "application"
  security_groups    = [var.security_group_id]
  subnets            = var.public_subnet_ids

  # Swarf's /revocations/:since is a Server-Sent Events firehose that clients
  # hold open indefinitely. The ALB default of 60 seconds would sever every
  # subscriber on a quiet minute.
  idle_timeout = var.idle_timeout

  enable_deletion_protection = var.deletion_protection

  tags = { Name = local.name }
}

# One wildcard certificate covers every service hostname in the stage, so
# adding a service does not mean waiting on certificate validation.
resource "aws_acm_certificate" "this" {
  domain_name       = "*.${var.hostname_suffix}"
  validation_method = "DNS"

  subject_alternative_names = [var.hostname_suffix]

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = local.name }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for option in aws_acm_certificate.this.domain_validation_options :
    option.domain_name => option
    # The wildcard and the apex validate through the same record.
    if option.domain_name != var.hostname_suffix
  }

  zone_id = data.aws_route53_zone.this.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60

  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  # Services attach their own host-based rules. Anything unmatched is a
  # misconfigured DNS record rather than traffic worth guessing about.
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "no service is routed at this hostname"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
