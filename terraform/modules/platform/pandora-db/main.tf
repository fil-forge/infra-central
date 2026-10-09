# The SpiderOak compatibility server's database: a second Aurora cluster, in
# subnets of its own, that the server's appliances reach over the stage's
# site-to-site VPN. Central's database subnets keep only the VPC's local route,
# and central's cluster stays unreachable from outside the VPC.
#
# The stage's VPN gateway (../pandora-vpn) propagates each site's route into the
# cluster's route table only. The pandora database and its roles are created by
# the provision Lambda's seed phase.
#
# See docs/decisions/2026-10-compat-server-database.md.

locals {
  name = "fc-${var.stage}-pandora-db"

  # /20 indexes 12 to 15 of the VPC sit inside one free /18 (10.20.192.0/18 by
  # default), which is the one route an appliance sends into the tunnel. Indexes
  # 9 to 11 could not be covered by one route without central's third database
  # subnet.
  first_subnet_index = 12
}

resource "aws_subnet" "this" {
  for_each = { for index, az in var.availability_zones : az => index }

  vpc_id            = var.vpc_id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, local.first_subnet_index + each.value)

  tags = { Name = "${local.name}-${each.key}" }
}

# The VPC's local route plus one propagated route per site, to the /32 its
# appliance source-NATs database traffic to. No NAT, internet gateway or S3
# endpoint, as in central's database subnets.
resource "aws_route_table" "this" {
  vpc_id = var.vpc_id

  # Empty and authoritative: a route added by hand is removed on the next
  # apply. Propagated routes are not part of this list.
  route            = []
  propagating_vgws = [var.vpn_gateway_id]

  tags = { Name = local.name }
}

resource "aws_route_table_association" "this" {
  for_each = aws_subnet.this

  subnet_id      = each.value.id
  route_table_id = aws_route_table.this.id
}

# Applies to every database on the cluster, which is why the pandora database
# has a cluster of its own rather than sharing central's.
resource "aws_security_group" "this" {
  name        = local.name
  description = "The pandora database, reachable only from the provision Lambda and the compatibility server sites"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from the provision Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.lambda_security_group_id]
  }

  dynamic "ingress" {
    for_each = var.sites

    content {
      description = "Postgres from the ${ingress.key} site, over the VPN"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [ingress.value.private_ip]
    }
  }

  tags = { Name = local.name }
}

module "aurora" {
  source = "../aurora"

  stage             = var.stage
  name              = local.name
  subnet_ids        = [for subnet in aws_subnet.this : subnet.id]
  security_group_id = aws_security_group.this.id
  kms_key_arn       = var.kms_key_arn

  instance_count        = var.instance_count
  backup_retention_days = var.backup_retention_days
  deletion_protection   = var.protect
  skip_final_snapshot   = !var.protect
}
