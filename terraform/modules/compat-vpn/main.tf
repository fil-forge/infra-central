# The AWS side of the site-to-site VPN between a stage's compatibility server
# appliances and that stage's pandora database cluster: one virtual private
# gateway per stage, and per appliance site a customer gateway and a VPN
# connection with two tunnels.
#
# It lives in the regional bootstrap rather than the platform root because a
# VPC cannot be deleted while a gateway is attached to it. The platform root
# attaches this gateway and propagates its routes into the cluster's route
# table, so a destroy of that root detaches the gateway and leaves the tunnels'
# addresses and keys here.
#
# See docs/decisions/2026-10-compat-server-database.md and
# docs/compat-server-vpn.md.

locals {
  name = "fc-${var.stage}-compat"

  # A stage with no sites gets no gateway, so a stage that never runs the
  # compatibility server carries nothing of it.
  enabled = length(var.sites) > 0

  # strongSwan in Debian 12 and 13 and Ubuntu 24.04 supports all of these.
  # AWS's defaults also accept AES-128, SHA-1 and DH group 2, which an
  # appliance could otherwise negotiate down to.
  ike_versions          = ["ikev2"]
  encryption_algorithms = ["AES256-GCM-16"]
  integrity_algorithms  = ["SHA2-384"]
  dh_group_numbers      = [20, 21]
}

resource "aws_vpn_gateway" "this" {
  count = local.enabled ? 1 : 0

  tags = { Name = local.name }
}

# Defined by the site's public address: a new address needs a new customer
# gateway, and the VPN connection moves to it in place.
resource "aws_customer_gateway" "this" {
  for_each = var.sites

  type       = "ipsec.1"
  ip_address = each.value.public_ip

  # Static routing ignores it, but AWS requires one.
  bgp_asn = 65000

  tags = { Name = "${local.name}-${each.key}" }
}

resource "aws_vpn_connection" "this" {
  for_each = var.sites

  type                = "ipsec.1"
  vpn_gateway_id      = aws_vpn_gateway.this[0].id
  customer_gateway_id = aws_customer_gateway.this[each.key].id
  static_routes_only  = true

  # The keys go to Secrets Manager, out of Terraform state. AWS generates them.
  preshared_key_storage = "SecretsManager"

  tunnel1_ike_versions                 = local.ike_versions
  tunnel1_phase1_encryption_algorithms = local.encryption_algorithms
  tunnel1_phase1_integrity_algorithms  = local.integrity_algorithms
  tunnel1_phase1_dh_group_numbers      = local.dh_group_numbers
  tunnel1_phase2_encryption_algorithms = local.encryption_algorithms
  tunnel1_phase2_integrity_algorithms  = local.integrity_algorithms
  tunnel1_phase2_dh_group_numbers      = local.dh_group_numbers

  tunnel2_ike_versions                 = local.ike_versions
  tunnel2_phase1_encryption_algorithms = local.encryption_algorithms
  tunnel2_phase1_integrity_algorithms  = local.integrity_algorithms
  tunnel2_phase1_dh_group_numbers      = local.dh_group_numbers
  tunnel2_phase2_encryption_algorithms = local.encryption_algorithms
  tunnel2_phase2_integrity_algorithms  = local.integrity_algorithms
  tunnel2_phase2_dh_group_numbers      = local.dh_group_numbers

  tags = { Name = "${local.name}-${each.key}" }
}

# The site's database traffic is source-NATed to this address on the
# appliance, so it is the one route the gateway propagates for the site.
resource "aws_vpn_connection_route" "this" {
  for_each = var.sites

  vpn_connection_id      = aws_vpn_connection.this[each.key].id
  destination_cidr_block = each.value.private_ip
}
