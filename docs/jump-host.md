# The jump host

`terraform/envs/jump-host` builds one small EC2 instance in the prod account, in us-east-2, with an
Elastic IP. Operators SSH through it to an appliance whose provider admits SSH from allowlisted
addresses only, and the provider allowlists that Elastic IP. Operators reach the jump host over
SSH from any address, and their keys can do nothing there except open a connection to the
appliance.

| Piece | Choice |
|---|---|
| Instance | `t4g.nano`, Amazon Linux 2023 on arm64, IMDSv2 only, encrypted gp3 root volume |
| Network | its own VPC (`10.22.0.0/24`) with one public subnet; the Elastic IP is its only public address |
| Inbound | SSH on port 22 from anywhere (`ssh_ingress_cidrs`), public-key logins as `jump` only, with the keys in `ssh_public_keys` |
| SSH access | each key may only forward TCP to an address in `destination_cidrs` on `destination_port`; no shell, agent, X11 or reverse forwarding |
| SSH checks | after first boot's initial start, sshd starts only once a script confirms its effective settings are the relay-only ones |
| Host key | an ed25519 key made by Terraform and kept in state, so it survives a replacement |
| Repairs | SSM Session Manager, which gives a shell when SSH does not; EC2 Instance Connect is removed |
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
ssh_public_keys = [
  "ssh-ed25519 AAAA... alice@laptop",
  "ssh-ed25519 AAAA... bob@laptop",
]
destination_cidrs = ["203.0.113.10/32"] # the appliance's public address
```

```sh
cd terraform/envs/jump-host
tofu init
tofu apply
tofu output public_ip          # send this to the appliance's provider
tofu output -raw known_hosts; echo   # give this line to every operator
```

Give each key a comment naming its owner. sshd logs every login with the fingerprint of the key
used and its line in the key file, and logs each refused connection to an address it was not
given. It does not log the connections it allows. To match a fingerprint to an owner, run
`ssh-keygen -lf` on the tfvars keys.

## Connecting

Add the line from `tofu output -raw known_hosts` to `~/.ssh/known_hosts`, on a line of its own,
so the first connection checks the host key instead of asking you to accept it. Then, in
`~/.ssh/config`, with the Elastic IP from `tofu output public_ip`:

```
Host forge-jump
  HostName 198.51.100.7
  User jump
  IdentityFile ~/.ssh/<the key you listed in ssh_public_keys>
  IdentitiesOnly yes
  ForwardAgent no

Host appliance
  HostName 203.0.113.10
  User <appliance-user>
  ProxyJump forge-jump
```

`ssh appliance` then opens the session through the jump host, and the appliance sees it come from
the Elastic IP. Each hop has its own user: `jump` on the jump host, and whatever user the
appliance's provider set up there. Both logins use keys on your laptop, so your key has to be in
`ssh_public_keys` and in the appliance user's `authorized_keys`. The jump host only passes the
encrypted connection through and never holds a key for the appliance.

`HostName` under `appliance` has to be the address listed in `destination_cidrs`, not a DNS name:
the jump host forwards only to the exact addresses it was given. Check the appliance's host key
fingerprint with its provider before accepting it the first time.

`ssh forge-jump` on its own logs in and exits at once, since the jump host gives no shell.
"Connection refused" means sshd is down, most likely because its startup check failed. To look at
the host, open a shell through Session Manager, which needs the AWS CLI's
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html):

```sh
aws ssm start-session --profile <prod-profile> --region us-east-2 --target "$(tofu output -raw instance_id)"
sudo journalctl -t sshd -t sshd-session
sudo less /var/log/cloud-init-output.log
```

## Changing it

The keys, the destinations and the sshd settings are all written at first boot, so a change to
`ssh_public_keys`, `destination_cidrs` or `destination_port` replaces the instance. The new
instance keeps the Elastic IP and the host key, so operators change nothing and see the jump host
gone for a minute or two. The plan shows the instance's user data as a sensitive value, because it
carries the host key; check the key list in the tfvars file rather than in the plan.

Replacing the instance also discards its sshd log. Before removing a key that may have leaked,
save what it did with `sudo journalctl -t sshd -t sshd-session` through Session Manager.

A change to `ssh_ingress_cidrs` edits the security group in place. A change to `instance_type`
stops and restarts the instance. A new Amazon Linux AMI does not replace the instance on its own,
but each replacement boots the current one.

The host's private key sits in this root's state and in the instance's user data, which anyone
with read access to EC2 in the prod account can read. Someone holding it could pose as the jump
host to an operator whose traffic they already intercept. They could not log in with it, decrypt
recorded sessions, or read the relayed session, which is the operator's own SSH connection to the
appliance and checks the appliance's host key. To replace the host key, run
`tofu apply -replace=tls_private_key.host`, which also replaces the instance, and hand out the new
`known_hosts` line.
