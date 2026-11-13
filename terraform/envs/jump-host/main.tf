# A jump host with one static public IPv4 address, for operators to SSH
# through to an appliance whose provider admits SSH from a fixed address only.
# The provider allowlists the Elastic IP below. Operators SSH to the jump host
# directly, from any address, as the user jump, with a key listed in
# ssh_public_keys. sshd lets those keys do one thing: open a TCP connection to
# an address in destination_cidrs. There is no shell over SSH; SSM Session
# Manager stays as the way in for repairs.
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

variable "ssh_public_keys" {
  description = "OpenSSH public keys allowed to log in as the relay user, jump, one per operator, each on one line. Give each a comment naming its owner: sshd logs the fingerprint of the key behind every login."
  type        = list(string)

  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "List at least one key; with none, nobody can use the jump host."
  }

  validation {
    condition = alltrue([
      for k in var.ssh_public_keys :
      can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\\.com|sk-ecdsa-sha2-nistp256@openssh\\.com) [A-Za-z0-9+/]+={0,3}( [^\\r\\n]*)?$", trimspace(k)))
    ])
    error_message = "Each entry must be one OpenSSH public key line: type, base64 key, optional comment."
  }
}

variable "destination_cidrs" {
  description = "Addresses the jump host may open SSH connections to: the appliances it relays to, as /32s. The security group refuses SSH to anywhere else, and sshd refuses to forward to anywhere else."
  type        = list(string)

  validation {
    condition     = length(var.destination_cidrs) > 0
    error_message = "List at least one destination; the jump host has no other use."
  }

  # sshd's PermitOpen takes single addresses, so a wider block could pass the
  # security group but never be reachable through the jump host.
  validation {
    condition     = alltrue([for c in var.destination_cidrs : can(regex("^[0-9.]+/32$", c)) && try(cidrhost(c, 0) == trimsuffix(c, "/32"), false)])
    error_message = "Each destination must be a single IPv4 address written as a /32."
  }
}

variable "destination_port" {
  description = "Port the appliances' SSH daemons listen on."
  type        = number
  default     = 22
}

variable "ssh_ingress_cidrs" {
  description = "Addresses allowed to SSH to the jump host on port 22. Anywhere by default, since operators' addresses change and the keys and sshd's forwarding limits carry the access control. Empty closes the port and leaves SSM Session Manager as the only way in."
  type        = list(string)
  default     = ["0.0.0.0/0"]
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

# The host key is made here, kept in state, and installed by cloud-init before
# sshd first starts, so a replaced instance keeps the same host key and
# operators pin it once, from `tofu output -raw known_hosts`.
#
# The private key is readable by anyone who can read this root's state, by
# anyone in the prod account who can read the instance's user data
# (ec2:DescribeInstanceAttribute, which the AWS ReadOnlyAccess policy grants),
# and by any process on the instance through IMDS. Holding it lets someone pose
# as the jump host to an operator whose traffic they already intercept. It does
# not let them log in, since publickey signatures are bound to the session, or
# decrypt recorded sessions. Nor can they read what is relayed: that is the
# operator's own SSH session to the appliance, which checks the appliance's
# host key once the operator has pinned it.
resource "tls_private_key" "host" {
  algorithm = "ED25519"
}

locals {
  # Operators log in as this user, which has no shell, no password and no sudo.
  relay_user = "jump"

  # PermitOpen names exact host:port pairs. The client asks for the
  # appliance's HostName as written in its SSH config, so that has to be the
  # address itself, not a DNS name.
  permit_open = [for c in var.destination_cidrs : "${trimsuffix(c, "/32")}:${var.destination_port}"]

  # sshd keeps the first value it reads for a keyword, and the stock
  # sshd_config includes sshd_config.d/*.conf before its own settings, so this
  # file, sorting ahead of 50-redhat.conf, wins over both.
  #
  # The keys may only open TCP connections to the appliances: ProxyJump
  # (ssh -W) needs nothing more. ForceCommand applies to sessions, which
  # ProxyJump does not open, and turns any attempt at a shell or command into
  # an immediate exit. AuthorizedKeysCommand none turns off EC2 Instance
  # Connect, which the AMI configures as a second source of keys; sshd logs an
  # error for it on each refused key, which is harmless. LogLevel VERBOSE logs
  # each accepted key's fingerprint and each refused forward.
  #
  # MaxStartups and PerSourceMaxStartups keep one address from holding all the
  # unauthenticated connection slots. ClientAlive drops a vanished client after
  # two minutes, closing its connection to the appliance with it.
  sshd_config = <<-EOT
    HostKey /etc/ssh/ssh_host_ed25519_key
    AuthorizedKeysFile /etc/ssh/jump_authorized_keys
    AuthorizedKeysCommand none
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    HostbasedAuthentication no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    GSSAPIAuthentication no
    PermitRootLogin no
    AllowUsers ${local.relay_user}
    MaxAuthTries 3
    LoginGraceTime 20
    MaxStartups 10:30:60
    PerSourceMaxStartups 3
    ClientAliveInterval 30
    ClientAliveCountMax 4
    LogLevel VERBOSE

    PermitTTY no
    ForceCommand /sbin/nologin
    AllowAgentForwarding no
    X11Forwarding no
    AllowStreamLocalForwarding no
    PermitTunnel no
    PermitListen none
    GatewayPorts no
    AllowTcpForwarding local
    PermitOpen ${join(" ", local.permit_open)}
  EOT

  # Each key also carries its own limits, a second layer under the server
  # config: restrict turns everything off, port-forwarding turns forwarding
  # back on, permitopen limits outbound connections to the appliances, and
  # command does what ForceCommand does. Key options cannot refuse remote
  # forwarding while allowing -W; the server config above refuses it.
  key_options     = join(",", concat(["restrict", "port-forwarding", "command=\"/sbin/nologin\""], [for d in local.permit_open : "permitopen=\"${d}\""]))
  authorized_keys = join("", [for k in var.ssh_public_keys : "${local.key_options} ${trimspace(k)}\n"])

  # Run by sshd.service before every start after the first, including
  # restarts after an openssh update and every reboot. (The first start, early
  # in first boot, comes before systemd has read the drop-in that runs this;
  # the first-boot script restarts sshd through it a few seconds later.) sshd
  # starts only if its effective settings, as they apply to the relay user,
  # are the ones above. A failed check leaves sshd down, retried every 42
  # seconds by the stock unit, and Session Manager as the way in.
  #
  # The unit passes $OPTIONS from /etc/sysconfig/sshd as arguments, so the
  # check reads the settings with the same command-line options sshd gets.
  sshd_check = <<-EOT
    #!/bin/bash
    set -euo pipefail

    /usr/sbin/sshd -t "$@"
    effective=$(/usr/sbin/sshd -T "$@" -C user=${local.relay_user},host=check.invalid,addr=192.0.2.1)

    fail() { echo "jump-sshd-check: $1" >&2; exit 1; }
    for want in \
      'hostkey /etc/ssh/ssh_host_ed25519_key' \
      'authorizedkeysfile /etc/ssh/jump_authorized_keys' \
      'authorizedkeyscommand none' \
      'authenticationmethods publickey' \
      'hostbasedauthentication no' \
      'passwordauthentication no' \
      'kbdinteractiveauthentication no' \
      'permitrootlogin no' \
      'allowusers ${local.relay_user}' \
      'permittty no' \
      'forcecommand /sbin/nologin' \
      'allowagentforwarding no' \
      'x11forwarding no' \
      'allowstreamlocalforwarding no' \
      'permittunnel no' \
      'permitlisten none' \
      'gatewayports no' \
      'allowtcpforwarding local' \
      'permitopen ${join(" ", local.permit_open)}'; do
      grep -qxF "$want" <<<"$effective" || fail "expected '$want'"
    done
    [ "$(grep -c '^hostkey ' <<<"$effective" || true)" = 1 ] || fail "more than one host key"

    # The unit must start sshd the stock way, so that the options checked
    # above are the ones sshd runs with.
    execstart=$(systemctl show -P ExecStart sshd.service)
    [[ "$execstart" == *'argv[]=/usr/sbin/sshd -D $OPTIONS ;'* ]] || fail "sshd.service does not start sshd the stock way"
    [ "$(grep -o 'argv\[\]=' <<<"$execstart" | wc -l)" = 1 ] || fail "sshd.service has more than one ExecStart"
  EOT

  # Run once, at the end of first boot.
  #
  # EC2 Instance Connect is removed outright; the config above already
  # overrides it. sshd is stopped first, because the package's removal script
  # restarts a running sshd, and a failed check there would fail the removal.
  # sshd then starts through the check. If the check fails sshd stays down and
  # the script carries on, so the host still gets its updates, and exits
  # non-zero at the end.
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
  first_boot = <<-EOT
    #!/bin/bash
    set -euo pipefail

    status=0
    systemctl stop sshd
    pkgs=$(rpm -qa 'ec2-instance-connect*')
    if [ -n "$pkgs" ]; then
      rpm -e $pkgs || status=1
    fi
    systemctl daemon-reload
    systemctl start sshd || status=1

    dd if=/dev/zero of=/swapfile bs=1M count=1024
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap defaults 0 0' >> /etc/fstab

    echo latest > /etc/dnf/vars/releasever
    until dnf -y install dnf-automatic dnf-plugins-core; do sleep 10; done
    systemctl enable --now dnf-automatic-install.timer reboot-if-needed.timer

    exit "$status"
  EOT
}

# Amazon Linux 2023 ships the SSM agent and needs nothing installed to relay
# SSH. The AMI is read once: the instance ignores later changes to it, so a new
# release does not replace the instance. Updates arrive through dnf-automatic
# instead (see user_data).
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_instance" "this" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  # A cloud-config document. cloud-init's init stage, which runs before sshd
  # first starts, creates the relay user, installs the host key and writes
  # every file below, so sshd never serves another host key or config. The
  # first-boot script runs at the end of boot.
  #
  # user_data is read only at first boot, so any change to it (a key added or
  # removed, a new destination) replaces the instance. The replacement keeps
  # the Elastic IP and the host key, so operators notice nothing beyond a
  # minute or two without the jump host.
  user_data = "#cloud-config\n${yamlencode({
    users = [
      "default",
      {
        name        = local.relay_user
        shell       = "/sbin/nologin"
        lock_passwd = true
      },
    ]
    ssh_pwauth     = false
    ssh_deletekeys = true
    ssh_keys = {
      ed25519_private = tls_private_key.host.private_key_openssh
      ed25519_public  = tls_private_key.host.public_key_openssh
    }
    write_files = [
      { path = "/etc/ssh/sshd_config.d/10-jump.conf", permissions = "0600", content = local.sshd_config },
      { path = "/etc/ssh/jump_authorized_keys", permissions = "0644", content = local.authorized_keys },
      { path = "/usr/local/sbin/jump-sshd-check", permissions = "0755", content = local.sshd_check },
      { path = "/etc/systemd/system/sshd.service.d/10-jump-check.conf", permissions = "0644", content = "[Service]\nExecStartPre=/usr/local/sbin/jump-sshd-check $OPTIONS\n" },
      { path = "/usr/local/sbin/jump-first-boot", permissions = "0700", content = local.first_boot },
      {
        path        = "/etc/systemd/system/reboot-if-needed.service"
        permissions = "0644"
        content     = "[Service]\nType=oneshot\nExecStart=/bin/sh -c 'dnf needs-restarting -r || systemctl reboot'\n"
      },
      {
        path        = "/etc/systemd/system/reboot-if-needed.timer"
        permissions = "0644"
        content     = "[Timer]\nOnCalendar=*-*-* 04:00:00 UTC\n[Install]\nWantedBy=timers.target\n"
      },
    ]
    runcmd = [["/usr/local/sbin/jump-first-boot"]]
  })}"

  user_data_replace_on_change = true

  lifecycle {
    ignore_changes = [ami]
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
  description = "Session Manager target, for repairs when SSH is not working."
  value       = aws_instance.this.id
}

output "known_hosts" {
  description = "The line operators add to ~/.ssh/known_hosts to pin the jump host's host key."
  value       = "${aws_eip.this.public_ip} ${trimspace(tls_private_key.host.public_key_openssh)}"
}
