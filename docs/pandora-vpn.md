# Connecting a compatibility server site to the pandora database

The SpiderOak compatibility server keeps its database, `pandora`, on an Aurora cluster of its own
in central, and each appliance that runs the server reaches it over an AWS Site-to-Site VPN. The
cluster has no public endpoint. Why it is built this way:
[decisions/2026-10-compat-server-database.md](decisions/2026-10-compat-server-database.md).

The appliance's half (strongSwan, the private /32 and its source NAT) is in
[fil-forge/infra-nodes](https://github.com/fil-forge/infra-nodes).

| Piece | Root | Applied |
|---|---|---|
| Site list | `terraform/modules/shared/constants`, `pandora_sites` | read by the platform root |
| Service-linked role `AWSServiceRoleForVPCS2SVPN`, which keeps the pre-shared keys in Secrets Manager | `terraform/envs/bootstrap/prod/account` | by hand, once per account |
| VPN gateway, customer gateways, VPN connections | `terraform/envs/<stage>/platform` | by CI on merge |
| Subnets, security group, cluster | `terraform/envs/<stage>/platform`, `pandora_db` | by CI on merge |
| Database and roles | the provision Lambda's seed phase | by the platform apply |
| `AWS/VPN` in the metric stream, which feeds the tunnel alerts | `terraform/envs/bootstrap/prod/us-east-2` | by hand, once |

A stage gets a VPN gateway only when it has sites, and the cluster needs the stage to have at least
one site, because the appliances reach it only through that gateway. A stage can have sites without
the cluster; the platform plan warns about it, because each VPN connection costs about $44 a month.

## Adding a site

The site's operator provides:

- one static public IPv4 address. A change means a new customer gateway; the VPN connection moves
  to it in place and keeps its tunnel addresses and keys, after a brief outage.
- UDP 500, UDP 4500 and IP protocol 50 (ESP) open in both directions between that address and the
  two AWS tunnel addresses, with no upstream filtering or rate limiting of IPsec.
- the path MTU to the internet, expected to be 1,500 bytes.

Pick the site's private /32 from `10.21.0.0/24`. No other site in the same stage may use it, since
the stage's sites share one VPN and one security group; sites in different stages can reuse an
address. Add the site to the stage's map, keyed by its region label:

```hcl
prod = {
  us-east-9 = {
    public_ip  = "203.0.113.7"
    private_ip = "10.21.0.2/32"
  }
}
```

Both tunnels stay down from the apply until the appliance's strongSwan is up. Before merging,
silence the Grafana rules "Pandora VPN tunnel down" and "Pandora VPN both tunnels down" for the
stage's account until then.

Merge. CI applies the platform root, which creates the site's customer gateway and VPN connection,
and admits its private /32 to the cluster. The root's `pandora_vpn_connections` output, printed at
the end of the apply job, lists per site the VPN connection, both tunnel addresses and the ARN of
the Secrets Manager secret holding the pre-shared keys. Read the keys with:

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
| Phase 1 PRF | SHA2-384 |
| Phase 2 integrity | none, AES-GCM carries its own |
| DH groups, both phases | 20 or 21 |
| strongSwan proposals | `aes256gcm16-prfsha384-ecp384-ecp521` for IKE, `aes256gcm16-ecp384-ecp521` for ESP |
| Routing | static, route-based, one xfrm interface per tunnel |
| Tunnel MTU | 1,446 bytes on a 1,500-byte path, 1,438 behind NAT |

On Debian 12 and Ubuntu 24.04, strongSwan needs `libstrongswan-standard-plugins` for AES-GCM and
DH groups 20 and 21. It is only a recommended package, so an install with `--no-install-recommends`
leaves it out. Debian 13's base package is enough.

If the stage has no cluster yet, set `pandora_db` in its platform root, in the same pull
request as the site or a later one.

## Getting the database credentials onto the appliance

The seed phase stores one password and one DSN per role, under the role's own prefix in SSM:

| Role | Used by | SSM parameter |
|---|---|---|
| `pandora_admin` | the estate loader only; owns the database | `/forge-central/<stage>/pandora-admin/postgres-dsn` |
| `pandora_storage_server` | the server's daemons | `/forge-central/<stage>/pandora-storage-server/postgres-dsn` |

The DSNs ask for `sslmode=verify-full`. The client supplies the RDS root bundle, for example by
pointing `PGSSLROOTCERT` at
[global-bundle.pem](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem).

There is no automated path from central's SSM into an appliance's OpenBao yet. Someone with prod
access reads each DSN and installs it on the appliance by hand:

```bash
aws ssm get-parameter --with-decryption --name /forge-central/prod/pandora-storage-server/postgres-dsn --query Parameter.Value --output text
```

The `pandora_admin` DSN goes only to whoever runs the loader, and stays out of
`/etc/default/pandora`. Legacy tools connect as a role named `pandora` by default, and no such role
exists, so they fail rather than run as the owner.

## Checking the path

With the tunnels up, from the appliance, with traffic sourced from its private /32:

```bash
PGSSLROOTCERT=/path/to/global-bundle.pem psql "$PANDORA_STORAGE_SERVER_DSN" -c 'SHOW statement_timeout'
```

It prints `15s`. A connection from any other address times out.

The Grafana rule "Pandora VPN tunnel down" is a warning after one tunnel has been down for 15
minutes, and "Pandora VPN both tunnels down" is a critical after both have been down for five. Both
also fire when no `TunnelState` data arrives, about 20 and ten minutes after the last sample: the
query keeps returning that sample for Mimir's five-minute lookback before the wait starts. With more
than one site, the rules do not notice one VPN connection's data stopping while another's arrives.
The critical rule stays paused until the first production appliance runs strongSwan (FIL-1402); the
pull request that brings that site live replaces its `is_paused = true` in
`terraform/envs/grafana/alerts.tf` with the warning rule's expression, which pauses a rule while
prod has no site. An apply that changes a VPN connection's options or its customer gateway takes
both tunnels down, so silence both rules for it.

## Dropping the cluster

To drop the Aurora cluster instead of performing a data reset, set `pandora_db = null` in the
stage's platform root and merge. CI deletes the cluster, with no final snapshot when `protect` is
off, along with its subnets and security group. The VPN stays, with its tunnel addresses and keys.

Removing the VPN as well means deleting the stage's sites from `pandora_sites`, in the same
pull request or a later one. New tunnels later get new addresses and keys. Removing prod's last
site also pauses the VPN rules, through the Grafana root's apply on the same merge.

## Destroying the platform root

A destroy of the stage's platform root deletes the VPN with the VPC. When the root is applied again,
every site gets two new tunnel addresses and two new pre-shared keys. Its public IP, private /32,
the VPC route and the IPsec parameters stay the same. For each site, after the apply:

1. Read the new tunnel addresses from `pandora_vpn_connections` and the new keys from Secrets
   Manager, as in [Adding a site](#adding-a-site), and send them to the site's operator.
2. The operator replaces the keys in the node's OpenBao and the tunnel addresses in the node's
   configuration, then re-runs the node's VPN provisioning, as infra-nodes describes.
3. Check the path as above.

The site cannot reach its database from the destroy until its operator finishes. A data wipe that
keeps the platform root, or dropping only the cluster, leaves the tunnels as they are.
