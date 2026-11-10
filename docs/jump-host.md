# The jump host

`terraform/envs/jump-host` builds one small EC2 instance in the prod account, in us-east-2, with an
Elastic IP. Operators SSH through it to an appliance whose provider admits SSH from allowlisted
addresses only, and the provider allowlists that Elastic IP.

| Piece | Choice |
|---|---|
| Instance | `t4g.nano`, Amazon Linux 2023 on arm64, IMDSv2 only, encrypted gp3 root volume |
| Network | its own VPC (`10.22.0.0/24`) with one public subnet; the Elastic IP is its only public address |
| Inbound | none by default; operators arrive through SSM Session Manager |
| Outbound | SSH to `destination_cidrs` on `destination_port` (22 by default) only; HTTPS anywhere, for SSM and dnf |
| Updates | dnf-automatic installs each new Amazon Linux release's updates; the host reboots at 04:00 UTC when one needs it |
| Instance role | the five SSM agent actions Session Manager needs, and nothing else |
| Cost | about $7.40 a month at on-demand list prices |

The Elastic IP survives a replacement of the instance and has `prevent_destroy` set. A released
address can be recovered only while no other AWS account holds it, and a new one has to be
allowlisted again.

## Applying it

No workflow plans or applies this root. Apply it from a laptop with credentials for the prod
account. It needs two values, which are easiest to keep in a `jump-host.auto.tfvars` beside
`main.tf`. The repository ignores that file name.

```hcl
ssh_public_key    = "ssh-ed25519 AAAA... you@laptop"
destination_cidrs = ["203.0.113.10/32"] # the appliance's public address
```

```sh
cd terraform/envs/jump-host
tofu init
tofu apply
tofu output public_ip     # send this to the appliance's provider
tofu output instance_id   # i-..., used in the SSH config below
```

## Connecting

Install the AWS CLI's [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
Then, in `~/.ssh/config`, with the instance id from `tofu output instance_id` and the profile that
reaches the prod account:

```
Host forge-jump
  HostName i-0123456789abcdef0
  HostKeyAlias forge-jump
  User ec2-user
  ProxyCommand aws ssm start-session --profile <prod-profile> --region us-east-2 --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p

Host appliance
  HostName 203.0.113.10
  User <appliance-user>
  ProxyJump forge-jump
```

`ssh appliance` then opens the session through the jump host. Session Manager can take a few
minutes after the first apply to report the instance online; until then the `ProxyCommand` fails
with `TargetNotConnected`. The appliance sees the connection
come from the Elastic IP. The appliance key stays on the laptop: `ProxyJump` forwards only the TCP
stream, so the jump host never holds a key for the appliance.

To SSH to the jump host directly instead, list the operators' addresses in `ssh_ingress_cidrs` and
drop the `ProxyCommand` line, with `HostName` set to the Elastic IP.

## Changing it

A change to `destination_cidrs` or `ssh_ingress_cidrs` edits the security group in place. A change
to `instance_type` stops and restarts the instance. A change to `ssh_public_key` replaces it, since
EC2 installs the key at first boot only. The new instance keeps the Elastic IP but has a new
instance id and a new host key: copy `tofu output instance_id` into `HostName`, and expect SSH to
warn that the host key for `forge-jump` changed. A new Amazon Linux AMI does not replace the
instance.
