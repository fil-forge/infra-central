# VPC, subnets and the security groups every other module attaches to.
#
# Egress is not optional here. Tasks pull images from GHCR, call the public
# Filecoin RPC, and resolve each other's did:web identities over HTTPS, which
# means a task in a private subnet reaches the public ALB back through the NAT
# gateway. A design without NAT would need a private DNS override per service
# hostname and would still leave the chain RPC unreachable.

locals {
  name = "fc-${var.stage}"

  # Two AZs is the minimum RDS multi-AZ and the ALB both require.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

data "aws_availability_zones" "available" {
  state = "available"
}

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
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, each.value + length(local.azs))

  tags = { Name = "${local.name}-private-${each.key}" }
}

# One NAT gateway rather than one per AZ. It is a single point of failure for
# egress and roughly halves the standing cost; raising it to one per AZ is a
# per-stage decision rather than a rewrite.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[local.azs[0]].id
  depends_on    = [aws_internet_gateway.this]

  tags = { Name = local.name }
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
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
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

# The Lambda reaches OpenBao over the same private path hilt uses, so the task
# security group has to accept it. Declared separately to avoid a cycle between
# the two group definitions.
resource "aws_security_group_rule" "service_from_lambda" {
  description              = "OpenBao from the provision Lambda"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.service.id
  source_security_group_id = aws_security_group.lambda.id
}
