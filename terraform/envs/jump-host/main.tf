# A jump host with one static public IPv4 address, for operators to SSH
# through to an appliance whose provider admits SSH from a fixed address only.
# The provider allowlists the Elastic IP below; operators reach the jump host
# through SSM Session Manager, so it needs no inbound port open.
#
# Applied by hand from a laptop, like the bootstrap roots. No workflow plans or
# applies it. See docs/jump-host.md for applying it and for the SSH config.
#
# At on-demand list prices in us-east-2 it costs about $7.40 a month: the
# t4g.nano instance $3.07, the public IPv4 address $3.65, the 8 GiB gp3 root
# volume $0.64.

provider "aws" {
  region = "us-east-2"

  allowed_account_ids = [module.constants.prod_account_id]
}

module "constants" {
  source = "../../modules/shared/constants"
}

locals {
  name = "fc-jump-host"
}

variable "ssh_public_key" {
  description = "OpenSSH public key installed for ec2-user, the key operators log in to the jump host with. TF_VAR_ssh_public_key."
  type        = string
}

variable "destination_cidrs" {
  description = "Addresses the jump host may open SSH connections to: the appliances it relays to, as /32s. SSH to anywhere else is refused by the security group."
  type        = list(string)

  validation {
    condition     = length(var.destination_cidrs) > 0
    error_message = "List at least one destination; the jump host has no other use."
  }
}

variable "destination_port" {
  description = "Port the appliances' SSH daemons listen on."
  type        = number
  default     = 22
}

variable "ssh_ingress_cidrs" {
  description = "Addresses allowed to SSH to the jump host directly on port 22. Empty by default, which leaves SSM Session Manager as the only way in."
  type        = list(string)
  default     = []
}

variable "instance_type" {
  description = "Instance type. Must be arm64 (Graviton), to match the AMI."
  type        = string
  default     = "t4g.nano"
}

# Its own VPC, so the jump host shares no network with the stages. One public
# subnet and an internet gateway: VPCs, subnets and route tables cost nothing.
# 10.22.0.0/24 is clear of the stage VPCs (10.20.0.0/16) and the compatibility
# server sites (10.21.0.0/24), though nothing here routes to either.
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block = "10.22.0.0/24"

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = local.name }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = aws_vpc.this.cidr_block
  availability_zone = data.aws_availability_zones.available.names[0]

  # The Elastic IP is the instance's only public address. An auto-assigned one
  # would be a second billed IPv4 and a second source address the provider has
  # not allowlisted.
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "this" {
  name        = local.name
  description = "Jump host: SSH out to the appliances, HTTPS out for SSM and package updates"
  vpc_id      = aws_vpc.this.id

  dynamic "ingress" {
    for_each = length(var.ssh_ingress_cidrs) > 0 ? [1] : []
    content {
      description = "Direct SSH from operators"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_ingress_cidrs
    }
  }

  egress {
    description = "SSH to the appliances"
    from_port   = var.destination_port
    to_port     = var.destination_port
    protocol    = "tcp"
    cidr_blocks = var.destination_cidrs
  }

  # The SSM agent's endpoints and the Amazon Linux package repositories are
  # both HTTPS. DNS to the VPC resolver and NTP to the Time Sync Service are
  # link-local and never pass through a security group.
  egress {
    description = "SSM Session Manager and dnf"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = local.name }
}

# The instance role allows only what the SSM agent needs to register and carry
# sessions. AmazonSSMManagedInstanceCore is not used: it also grants
# ssm:GetParameter on every parameter, which would let anyone with root here
# read the prod stage's SecureStrings.
resource "aws_iam_role" "this" {
  name = local.name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "session_manager" {
  name = "session-manager"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = local.name
  role = aws_iam_role.this.name
}

# EC2 writes the key into authorized_keys at first boot only. Naming the key
# pair after the key's hash makes a new key a new key_name, which replaces the
# instance, so the key in state and the key on the host cannot differ.
resource "aws_key_pair" "this" {
  key_name   = "${local.name}-${substr(sha256(trimspace(var.ssh_public_key)), 0, 8)}"
  public_key = var.ssh_public_key
}

# Amazon Linux 2023 ships the SSM agent and needs nothing installed to relay
# SSH. The AMI is read once: the instance ignores later changes to it, so a new
# release does not replace the instance and change its host key. Updates arrive
# through dnf-automatic instead (see user_data).
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_instance" "this" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  key_name               = aws_key_pair.this.key_name

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  # user_data runs once, at first boot.
  #
  # The swapfile keeps dnf from being OOM-killed in the nano's 512 MiB.
  #
  # AL2023 pins dnf to the release the AMI was built from, and a release never
  # gets new packages. Setting releasever to latest lets dnf-automatic install
  # each new release's updates. A nightly timer reboots only when an update
  # needs it (a new kernel, glibc or systemd), at 04:00 UTC.
  #
  # The instance boots with no public address and reaches the internet only
  # once the Elastic IP is associated, a few seconds into the apply, so the
  # install retries until it can reach the repositories.
  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    dd if=/dev/zero of=/swapfile bs=1M count=1024
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap defaults 0 0' >> /etc/fstab

    echo latest > /etc/dnf/vars/releasever
    until dnf -y install dnf-automatic dnf-plugins-core; do sleep 10; done
    sed -i 's/^apply_updates = .*/apply_updates = yes/' /etc/dnf/automatic.conf
    systemctl enable --now dnf-automatic.timer

    cat > /etc/systemd/system/reboot-if-needed.service <<'UNIT'
    [Service]
    Type=oneshot
    ExecStart=/bin/sh -c 'dnf needs-restarting -r || systemctl reboot'
    UNIT
    cat > /etc/systemd/system/reboot-if-needed.timer <<'UNIT'
    [Timer]
    OnCalendar=*-*-* 04:00:00 UTC
    [Install]
    WantedBy=timers.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now reboot-if-needed.timer
  EOF

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = { Name = local.name }
}

# The address the provider allowlists. It is created and kept apart from the
# instance, so replacing the instance moves the same address to the new one.
# prevent_destroy keeps a `tofu destroy` from releasing it: a released address
# can be recovered only while no other account holds it, and a new one means
# asking the provider again. To retire
# the jump host for good, remove the lifecycle block first.
resource "aws_eip" "this" {
  domain = "vpc"

  tags = { Name = local.name }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_eip_association" "this" {
  allocation_id = aws_eip.this.id
  instance_id   = aws_instance.this.id
}

output "public_ip" {
  description = "The static address to give the appliance's provider."
  value       = aws_eip.this.public_ip
}

output "instance_id" {
  description = "Session Manager target for the SSH ProxyCommand."
  value       = aws_instance.this.id
}
