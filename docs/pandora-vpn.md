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
| `locker` | the server's stats lock tool | `/forge-central/<stage>/locker/postgres-dsn` |
| `pandora_migration` | the import service, the capture load, the sync and the stage record, on the appliance | `/forge-central/<stage>/pandora-migration/postgres-dsn` |

`pandora_storage_server` has a 15-second `statement_timeout` and a 30-second
`idle_in_transaction_session_timeout`. `pandora_migration` has no statement
timeout, since its bulk statements run long, and an `idle_in_transaction_session_timeout` of 30
seconds. `locker` has neither: it holds a session-level advisory lock while idle in a transaction
for the whole stats dump, which takes minutes. On the appliance, its connection goes straight to the database
or through a session pool, never a transaction pool, because transaction pooling can pass its
backend and the lock to another client. `locker`'s parameters sit at the stage root, so no central
service may take the name `locker`. The server's grants file gives each role its table privileges.

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
Both rules stay paused until the first production appliance runs strongSwan (FIL-1402). The pull
request that brings that site live replaces their `is_paused = true` in
`terraform/envs/grafana/alerts.tf` with `length(module.constants.pandora_sites.prod) == 0`, which
pauses a rule while prod has no site. An apply that changes a VPN connection's options or its
customer gateway takes both tunnels down, so silence both rules for it.

### Checking a site before its appliance is configured

Two scripts check a site's VPN connection without the appliance's own strongSwan. Both use the
stage's real tunnels, so silence the Grafana rules "Pandora VPN tunnel down" and "Pandora VPN both
tunnels down" for the run. Outside the run both tunnels are down until the appliance's strongSwan is
up, and during it the host check takes tunnel 1 down on purpose.

The host check runs strongSwan and psql in containers on the site's appliance host, and leaves the
host's network configuration alone. Start it from a laptop with credentials for the stage's account:

```bash
scripts/fetch-pandora-vpn-secrets.sh --stage prod --site provisional --host root@23.83.66.244
```

```bash
ssh -t root@23.83.66.244 bash /run/pandora-vpn-check/check-pandora-vpn-host.sh
```

The first copies the check, the tunnel addresses, the keys, the `pandora_storage_server` DSN and the
RDS CA bundle to `/run/pandora-vpn-check` on the host, a tmpfs. Debian and Ubuntu mount `/run`
noexec, so the second runs the check through bash. It brings both tunnels up,
queries the cluster through tunnel 1, then through tunnel 2 with tunnel 1 down. With both tunnels
back up it prints the command that shows their status on the AWS side, waits for Enter, and removes
its containers, images and `/run/pandora-vpn-check`. Nothing else on the host may initiate IKE
while it runs, since two initiators from one address compete for the same tunnels.

The laptop check confirms that no tunnel establishes from any other address:

```bash
scripts/check-pandora-vpn-laptop.sh --stage prod --site provisional
```

It attempts IKE with both tunnels using the site's identity and real keys, and passes when neither
tunnel establishes. AWS normally does not answer an unknown peer at all, and a firewall dropping UDP
500 or 4500 on the laptop's path looks the same, so the script says whether AWS answered: only an
answer shows that AWS saw the attempt. The keys stay in a temporary directory removed on exit.

A host check that cannot remove its containers keeps `/run/pandora-vpn-check`, since the containers
may still hold the keys and the DSN, and exits with an error.

A host run interrupted before its cleanup leaves its containers and secrets behind, and the next
fetch refuses to overwrite them. Remove them from the laptop with:

```bash
ssh root@23.83.66.244 docker compose -f /run/pandora-vpn-check/pandora-vpn-check/compose.yml down --rmi local --volumes
```

```bash
ssh root@23.83.66.244 rm -rf /run/pandora-vpn-check
```

A reboot also clears the secrets.

## The cluster's PostgreSQL version

The cluster runs Aurora PostgreSQL 18, set by `pandora_db.engine_version` in the stage's platform
root, apart from the stage's own cluster, which stays on 16. Today it holds the pack ledger that the
import service on the appliance writes as `pandora_migration`.

A new minor release is a one-line change to `engine_version`, applied in place. A new major version
is not, because the cluster's parameter group is named for its major version and the `aurora` module
performs no major upgrade. A cluster that holds production data needs an in-place major upgrade,
and that procedure has to be designed before the next major version. Never drop such a cluster.
While the cluster holds only test data it is dropped and created again, in two pull requests that
each get their own apply:

1. Set `pandora_db = null` and merge. CI deletes the cluster as in
   [Dropping the cluster](#dropping-the-cluster). The seed phase runs again with no pandora host and
   leaves the stored passwords and DSNs in SSM.
2. Restore `pandora_db` with the new `engine_version` and merge. CI creates the cluster. Its
   endpoint name follows the cluster's identifier, so the host is expected to stay the same. The seed
   phase runs again because its pandora host input changes, and creates the `pandora` database and
   its roles with the passwords already in SSM, so `seed_trigger` stays as it is. If the seed phase
   does not run, bump `seed_trigger`.

Merging both in one apply fails: the cluster would need a major upgrade, and the old parameter
group would be destroyed while the cluster still uses it. Once the cluster is back, compare each
stored DSN's host with the one installed on the appliance, and reinstall any that differ. The
ledger's schema and grants come back only when `pandora_admin` applies them again from the
server's own files.

## Dropping the cluster

To drop the Aurora cluster instead of performing a data reset, set `pandora_db = null` in the
stage's platform root and merge. CI deletes the cluster, with no final snapshot when `protect` is
off, along with its subnets, security group and parameter group. The VPN stays, with its tunnel
addresses and keys.

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
