# One ALB for the whole stage, with host-based routing to each service.
#
# Public hostnames are not cosmetic here. Services identify each other by
# did:web, which resolves by fetching https://<host>/.well-known/did.json, so
# every service that other services authenticate must be reachable at a real
# name with a real certificate.

locals {
  name = "fc-${var.stage}"

  # Dev and staging write every record into one delegated zone. Prod's service
  # names sit directly beneath a Cloudflare apex, so each one is delegated to
  # Route53 as a zone of its own, and a null zone_name selects that layout.
  zone_per_hostname = var.zone_name == null

  # Sorted so the certificate's primary name does not move when a service is
  # added; a new name in the middle of the list would replace the certificate
  # for nothing.
  hostnames = sort(var.hostnames)
}

data "aws_route53_zone" "this" {
  count = local.zone_per_hostname ? 0 : 1

  name         = var.zone_name
  private_zone = false
}

data "aws_route53_zone" "hostname" {
  for_each = local.zone_per_hostname ? toset(local.hostnames) : toset([])

  name         = each.key
  private_zone = false
}

locals {
  zone_ids = {
    for hostname in local.hostnames : hostname => (
      local.zone_per_hostname
      ? data.aws_route53_zone.hostname[hostname].zone_id
      : data.aws_route53_zone.this[0].zone_id
    )
  }
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

  # A header whose name is not valid HTTP is dropped rather than passed on.
  # This closes the request-smuggling class where the ALB and the service
  # behind it disagree about where one request ends and the next begins.
  # Underscores stay legal, so nothing the services or a did:web resolver
  # sends is affected.
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.access_logs.id
    enabled = true
  }

  # Turning access logs on makes ELB test-write to the bucket immediately, which
  # fails unless the policy granting it is already in place. Referencing the
  # bucket does not order that on its own.
  depends_on = [aws_s3_bucket_policy.access_logs]

  tags = { Name = local.name }
}

# Where every hostname shares a zone, one wildcard certificate covers them all,
# so adding a service does not mean waiting on certificate validation.
#
# Where each hostname has its own zone, a wildcard cannot work: the validation
# record for *.fil-forge.com belongs in the fil-forge.com zone, which is in
# Cloudflare. The certificate names each hostname instead, and each one
# validates in its own zone.
resource "aws_acm_certificate" "this" {
  domain_name       = local.zone_per_hostname ? local.hostnames[0] : "*.${var.hostname_suffix}"
  validation_method = "DNS"

  subject_alternative_names = (
    local.zone_per_hostname
    ? slice(local.hostnames, 1, length(local.hostnames))
    : [var.hostname_suffix]
  )

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
    if local.zone_per_hostname || option.domain_name != var.hostname_suffix
  }

  zone_id = local.zone_per_hostname ? local.zone_ids[each.key] : data.aws_route53_zone.this[0].zone_id
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
