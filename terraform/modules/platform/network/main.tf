# VPC, subnets and the security groups every other module attaches to.
#
# Egress is not optional here. Tasks pull images from GHCR, call the public
# Filecoin RPC, and resolve each other's did:web identities over HTTPS, which
# means a task in a private subnet reaches the public ALB back through the NAT
# gateway. A design without NAT would need a private DNS override per service
# hostname and would still leave the chain RPC unreachable.

locals {
  name = "fc-${var.stage}"

  # Two AZs is the minimum RDS multi-AZ and the ALB both require; a stage that
  # wants to survive losing one sets az_count higher. Read that variable's
  # description before changing it on a stage that already exists.
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # NAT gateways and private route tables are index-aligned: table N routes
  # through gateway N, which lives in AZ N. With nat_gateway_per_az off there
  # is one of each and every private subnet points at index 0.
  nat_count = var.nat_gateway_per_az ? var.az_count : 1
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  for_each = { for index, az in local.azs : az => index }

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, each.value)
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-public-${each.key}" }
}

resource "aws_subnet" "private" {
  for_each = { for index, az in local.azs : az => index }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, each.value + var.az_count)

  tags = { Name = "${local.name}-private-${each.key}" }
}

# How many NAT gateways a stage runs is nat_gateway_per_az's decision: one
# shared gateway is a single point of failure for egress at roughly half the
# standing cost, one per AZ survives losing a zone. The names below keep their
# unsuffixed form in the shared layout so a stage that has never turned this on
# sees no churn.
resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"
  tags   = { Name = var.nat_gateway_per_az ? "${local.name}-nat-${local.azs[count.index]}" : "${local.name}-nat" }
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[local.azs[count.index]].id
  depends_on    = [aws_internet_gateway.this]

  tags = { Name = var.nat_gateway_per_az ? "${local.name}-${local.azs[count.index]}" : local.name }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table" "private" {
  count = local.nat_count

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }

  tags = { Name = var.nat_gateway_per_az ? "${local.name}-private-${local.azs[count.index]}" : "${local.name}-private" }
}

# These three were single resources when every stage shared one NAT gateway.
# Pinning the existing objects to index 0 keeps a stage that is already up from
# tearing its egress path down and back up to gain a count.
moved {
  from = aws_eip.nat
  to   = aws_eip.nat[0]
}

moved {
  from = aws_nat_gateway.this
  to   = aws_nat_gateway.this[0]
}

moved {
  from = aws_route_table.private
  to   = aws_route_table.private[0]
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[var.nat_gateway_per_az ? index(local.azs, each.key) : 0].id
}

# Sprue's bucket traffic would otherwise leave through the NAT gateway: metered
# by the gigabyte, and an odd dependency of an upload on the egress path. A
# gateway endpoint costs nothing and keeps it inside AWS. Attached to the public
# table too, which is free and covers anything ever placed there.
#
# This does not fight the inline route blocks above. The provider ignores
# endpoint-managed (vpce-) routes when it reads a route table, which is only
# true of the gateway association below — writing the same route as an
# aws_route resource would collide with the authoritative inline sets.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id], aws_route_table.private[*].id)

  tags = { Name = "${local.name}-s3" }
}

# Private DNS for service-to-service calls that do not need a public identity:
# plc, which smelt also keeps unrouted, and OpenBao's internal address for hilt.
resource "aws_service_discovery_private_dns_namespace" "internal" {
  name = "forge-central.internal"
  vpc  = aws_vpc.this.id
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public ingress to the Forge load balancer"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP, redirected to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To the service tasks"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-alb" }
}

resource "aws_security_group" "service" {
  name        = "${local.name}-service"
  description = "Forge ECS tasks"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "From the load balancer"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "Between tasks, for plc and OpenBao over private DNS"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  # The Lambda reaches OpenBao over the same private path hilt uses, so the
  # task group has to accept it. Inline rather than a separate
  # aws_security_group_rule: inline blocks are the authoritative set for a
  # group, and a rule declared outside one is stripped on the next apply.
  ingress {
    description     = "OpenBao from the provision Lambda"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  egress {
    description = "Image pulls, chain RPC, and did:web resolution"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-service" }
}

resource "aws_security_group" "lambda" {
  name        = "${local.name}-lambda"
  description = "The provision Lambda, which needs RDS and OpenBao"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "RDS, OpenBao, and the SSM and Secrets Manager APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-lambda" }
}

resource "aws_security_group" "database" {
  name        = "${local.name}-database"
  description = "RDS Postgres, reachable only from tasks and the provision Lambda"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Postgres from the service tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.service.id]
  }

  ingress {
    description     = "Postgres from the provision Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  tags = { Name = "${local.name}-database" }
}
