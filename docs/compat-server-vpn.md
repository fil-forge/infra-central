# Connecting a compatibility server site to the pandora database

The SpiderOak compatibility server keeps its database, `pandora`, on an Aurora cluster of its own
in central, and each appliance that runs the server reaches it over an AWS Site-to-Site VPN. The
cluster has no public endpoint. Why it is built this way:
[decisions/2026-10-compat-server-database.md](decisions/2026-10-compat-server-database.md).

The appliance's half (strongSwan, the private /32 and its source NAT) is in
[fil-forge/infra-nodes](https://github.com/fil-forge/infra-nodes).

| Piece | Root | Applied |
|---|---|---|
| Site list | `terraform/modules/shared/constants`, `compat_server_sites` | read by both roots below |
| VPN gateway, customer gateways, VPN connections | `terraform/envs/bootstrap/<account>/<region>` | by hand |
| Gateway attachment, subnets, security group, cluster | `terraform/envs/<stage>/platform`, `compat_database` | by CI on merge |
| Database and roles | the provision Lambda's seed phase | by the platform apply |

The cluster needs the stage to have at least one site, because it attaches the stage's VPN
gateway, and the bootstrap root creates that gateway only for a stage with sites. A stage can have
sites without the cluster; the platform plan warns about it, because each VPN connection costs
about $44 a month.

## Adding a site

The site's operator provides:

- one static public IPv4 address. A change means a new customer gateway; the VPN connection moves
  to it in place and keeps its tunnel addresses and keys, after a brief outage.
- UDP 500, UDP 4500 and IP protocol 50 (ESP) open in both directions between that address and the
  two AWS tunnel addresses, with no upstream filtering or rate limiting of IPsec.
- the path MTU to the internet, expected to be 1,500 bytes.

Pick the site's private /32 from `10.21.0.0/24`, unused by any other site, and add the site to the
stage's map, keyed by its region label:

```hcl
prod = {
  us-east-9 = {
    public_ip  = "203.0.113.7"
    private_ip = "10.21.0.2/32"
  }
}
```

Merge, then apply the regional bootstrap by hand:

```bash
tofu -chdir=terraform/envs/bootstrap/prod/us-east-2 apply
```

Its `compat_vpn_sites` output lists, per site, the VPN connection, both tunnel addresses and the
ARN of the Secrets Manager secret holding the pre-shared keys. Read the keys with:

```bash
aws secretsmanager get-secret-value --secret-id <preshared_key_arn> --query SecretString --output text
```

Send the operator the two tunnel addresses, the keys over a secure channel, the site's private /32
and the parameters below. The VPC's side of the tunnel is `10.20.192.0/18`: the appliance routes
only that into the tunnel.

| Setting | Value |
|---|---|
| IKE | IKEv2 only |
| Phase 1 and 2 encryption | AES256-GCM-16 |
| Phase 1 and 2 integrity | SHA2-384 |
| DH groups, both phases | 20 or 21 |
| Routing | static, route-based, one xfrm interface per tunnel |
| Tunnel MTU | 1,446 bytes on a 1,500-byte path, 1,438 behind NAT |

If the stage has no cluster yet, set `compat_database` in its platform root and merge. A stage that
already has one picks up the new site's security-group rule on the next CI apply.

## Getting the database credentials onto the appliance

The seed phase stores one password and one DSN per role, under the role's own prefix in SSM:

| Role | Used by | SSM parameter |
|---|---|---|
| `pandora` | the estate loader only | `/forge-central/<stage>/pandora/postgres-dsn` |
| `pandora_storage_server` | the server's daemons | `/forge-central/<stage>/pandora-storage-server/postgres-dsn` |
| `ergo_proxy` | ergo_proxy's lookups | `/forge-central/<stage>/ergo-proxy/postgres-dsn` |

The DSNs ask for `sslmode=verify-full`. The client supplies the RDS root bundle, for example by
pointing `PGSSLROOTCERT` at
[global-bundle.pem](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem).

There is no automated path from central's SSM into an appliance's OpenBao yet. Someone with prod
access reads each DSN and installs it on the appliance by hand:

```bash
aws ssm get-parameter --with-decryption --name /forge-central/prod/pandora-storage-server/postgres-dsn --query Parameter.Value --output text
```

The `pandora` DSN goes only to whoever runs the loader. It stays out of `/etc/default/pandora`,
because legacy tools connect as `pandora` by default and would then run as the owner.

## Checking the path

With the tunnels up, from the appliance, with traffic sourced from its private /32:

```bash
PGSSLROOTCERT=/path/to/global-bundle.pem psql "$PANDORA_STORAGE_SERVER_DSN" -c 'SHOW statement_timeout'
```

It prints `15s`. A connection from any other address times out. The Grafana rule "Compatibility
server VPN tunnel down" fires while either tunnel is down, which includes the time between the
bootstrap apply and the appliance's strongSwan coming up.

## Reattaching the gateway, once

Run this once, after the first site's tunnels are up and before the first data reset. It shows
whether a VPN connection keeps its tunnel addresses while its gateway is detached and attached
again, which is what a reset of the platform root does.

1. Note both tunnel addresses from the bootstrap root's `compat_vpn_sites` output.
2. Detach the gateway (`aws ec2 detach-vpn-gateway`), wait for it to report detached, and attach it
   again (`aws ec2 attach-vpn-gateway`).
3. Compare the tunnel addresses, and re-apply the platform root so its route propagation is
   restored.

Record the result in the decision record. If the addresses change, the fallback is to move each
connection to a new gateway (`aws ec2 modify-vpn-connection --vpn-gateway-id`), which AWS documents
as keeping the tunnel addresses and options.

## Dropping the cluster

To drop the Aurora cluster instead of performing a data reset, set `compat_database = null` in the
stage's platform root and merge. CI deletes the cluster, with no final snapshot when `protect` is
off, along with its subnets and security group, and detaches the gateway. The VPN stays.

Removing the VPN is a second step: delete the stage's sites from `compat_server_sites`, merge, and
apply the regional bootstrap by hand. It must come after the cluster is gone, because AWS cannot
delete a gateway that is still attached. New tunnels later get new addresses and keys.
