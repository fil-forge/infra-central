# Optional Global Accelerator in front of the ALB.
#
# It buys two things a stage with regional appliances wants: two static anycast
# addresses, which an operator can put in a firewall rule and never revisit, and
# an edge TCP termination that shortens the handshake for a client far from the
# region. It also brings Shield Standard to bear at the edge rather than at the
# load balancer.
#
# Off by default. It carries a fixed hourly charge plus premium data transfer,
# and neither of its benefits applies to a dev stage nothing dials into.
#
# Note for a teardown done by hand: with client IP preservation on, Global
# Accelerator puts its own managed network interfaces in the ALB's subnets.
# Terraform destroys these resources before the subnets, but a partial or
# manual teardown that removes the VPC first will hang on those interfaces.

resource "aws_globalaccelerator_accelerator" "this" {
  count = var.enable_global_accelerator ? 1 : 0

  name            = local.name
  ip_address_type = "IPV4"
  enabled         = true

  tags = { Name = local.name }
}

resource "aws_globalaccelerator_listener" "this" {
  count = var.enable_global_accelerator ? 1 : 0

  accelerator_arn = aws_globalaccelerator_accelerator.this[0].arn
  protocol        = "TCP"

  port_range {
    from_port = 80
    to_port   = 80
  }

  port_range {
    from_port = 443
    to_port   = 443
  }
}

resource "aws_globalaccelerator_endpoint_group" "this" {
  count = var.enable_global_accelerator ? 1 : 0

  listener_arn = aws_globalaccelerator_listener.this[0].arn

  endpoint_configuration {
    endpoint_id = aws_lb.this.arn
    weight      = 100

    # Stated rather than left to the default, because the access logs and every
    # service's view of its caller depend on it: without this they would all
    # see an accelerator address instead of the client's.
    client_ip_preservation_enabled = true
  }

  # No health check settings here: Global Accelerator ignores them for a load
  # balancer endpoint and takes the load balancer's health from its target
  # groups, counting the ALB healthy only while every target group has a healthy
  # target. So one broken service marks the whole endpoint unhealthy — which
  # costs nothing in this shape, because an endpoint group with no healthy
  # endpoint left routes to all of them rather than dropping traffic, and this
  # group holds the one ALB.
}
