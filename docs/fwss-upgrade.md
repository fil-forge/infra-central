# Upgrading FWSS

Dev, staging and prod run on one FilecoinWarmStorageService (FWSS) proxy on Calibration,
`0x55325AB46CDAB0FbDef559c810cd6bc95cBFEfFd`. Its owner is `0xDb3b19d1917107A5D2D2fadBa609C9Ac20902D52`, the
account that deployed it.

A new FWSS release reaches the stages one of two ways:

- **Path A, upgrade in place.** The release's modules are deployed and the proxy is migrated to them. The proxy
  address stays the same, so no stage changes configuration, nothing is reset and no data is lost. One upgrade moves
  dev, staging and prod together. This is the path for every release.
- **Path B, deploy a fresh proxy and reset onto it.** For a release that cannot be applied in place. Every Piri on the
  stage loses its stored blobs, because a proof set stays bound to the FWSS it was created under. Never use it in
  production.

FilOzone's [`UPGRADE-CHECKLIST.md`](https://github.com/fil-forge/filecoin-services/blob/main/service_contracts/tools/UPGRADE-CHECKLIST.md)
also names its paths A and B, for a different split. Forge's path A is its Procedure B, the josuke migration. Forge
has no use for its Path A, which moves a proxy off the v1.4.0 monolith once.

The owner is a single account whose keystore is held by one person. Moving ownership to a Safe would remove that
single key from every announce and migrate below.

## Path A: upgrade in place

The steps run in the [fil-forge/filecoin-services](https://github.com/fil-forge/filecoin-services) fork, from
`service_contracts/`. They need the josuke and evm CLIs at the revisions its `Makefile` pins (`make install-josuke`,
`make install-evm`) and Foundry at the version its localdev `Dockerfile` names.

### 1. Merge the release into the fork

Merge the upstream release tag into the fork's `main` in a pull request
([#6](https://github.com/fil-forge/filecoin-services/pull/6) merged v1.6.0). Its `smoke-test` jobs build the localdev
image, and merging publishes it as `ghcr.io/fil-forge/filecoin-localdev:<commit>`.

Read the release notes for two things before going further:

- Whether Piri and the signing service still create data sets and add pieces under the release. A release that drops
  a payload or EIP-712 type they send needs their new versions on every node first. 1.6.0 kept the five-field
  `dataSetCreated` payload and the `CreateDataSet` type, so neither changed.
- Steps the release adds to the migration. 1.6.0 wraps the migration of an existing proxy in
  `FWSSStorageTermsMigration`, which the checklist describes under B1.

### 2. Prove it on smelt

Move smelt to the new localdev image, as `systems/blockchain/README.md` in smelt describes, and run its end-to-end
tests. A fresh deploy inside the image can move the FWSS address in smelt's configs; that is local and says nothing
about the shared proxy.

To rehearse the upgrade itself, run steps 3 to 6 against a smelt stack still on the previous image, with a data set
that has pieces and a proof. Record smelt's proxy on chain 31337 in a local copy of `josuke.json` first, as the shared
proxy is recorded for 314159. After the migration, the same data set should keep proving and take new pieces. smelt's
delegator signs with the owner's Anvil key, so send `josuke deploy` from another Anvil account (see step 3).

### 3. Deploy the modules

```bash
export CHAIN=314159
export ETH_RPC_URL=https://api.calibration.node.glif.io/rpc/v1
export FWSS_PROXY_ADDRESS=0x55325AB46CDAB0FbDef559c810cd6bc95cBFEfFd
```

Confirm the proxy runs the dispatcher with the check under "Choose the Upgrade Path" in the checklist, then follow its
B1. `josuke deploy` builds the modules that changed since the `current` deployment `josuke.json` records for this
proxy, deploys them, and records them and the migration under `proposed`. `josuke verify` rebuilds them from source
and checks the migration installs exactly those routes.

Set the signing wallet for `josuke deploy` only. Foundry unlocks a configured keystore even for read-only calls, so
keep it out of the environment for every other step. Any funded account can deploy the modules; only the announcement
and the migration need the owner. `josuke deploy` reserves its nonces before it builds and sends minutes later, so
nothing else may send from that account while it runs, or the deploy fails with "nonce too low". Commit the
`proposed` entry in a pull request to the fork.

`josuke verify` rebuilds every commit the entry records from scratch. On a laptop that took 45 minutes for two
commits, so plan for each run in steps 3, 5 and 6.

### 4. Announce the migration

The owner announces the migration with a delay in epochs (30 seconds each). The delay gives a second person time to
check the pending plan and run `josuke verify` before it can run; upstream gives a day (2880 epochs) for a mainnet proxy with outside
integrators.

```bash
export MIGRATION=<the migration from step 3>
export UPGRADE_DELAY_EPOCHS=<delay>
cast chain-id                         # 314159
cast call --from 0xDb3b19d1917107A5D2D2fadBa609C9Ac20902D52 "$FWSS_PROXY_ADDRESS" \
  'announceMigration(address,uint96)' "$MIGRATION" "$UPGRADE_DELAY_EPOCHS"
cast send --account <owner keystore> "$FWSS_PROXY_ADDRESS" \
  'announceMigration(address,uint96)' "$MIGRATION" "$UPGRADE_DELAY_EPOCHS"
```

The `cast call` simulates the announcement as the owner without sending it. Read the pending plan afterwards, as the
checklist's "Read the pending plan" shows: its target is `$MIGRATION`, and its `afterEpoch` is the announcement's
block plus the delay.

### 5. Review during the delay

Someone other than the announcer reads the pending plan again and runs `josuke verify` against the committed
`josuke.json`. A later announcement replaces a pending one, so a plan whose target changed is a reason to stop.

### 6. Run the migration

After `afterEpoch`, rerun the checks, simulate as the owner and send:

```bash
cast call --from 0xDb3b19d1917107A5D2D2fadBa609C9Ac20902D52 "$FWSS_PROXY_ADDRESS" 'migrate(address)' "$MIGRATION"
cast send --account <owner keystore> "$FWSS_PROXY_ADDRESS" 'migrate(address)' "$MIGRATION"
```

Then run the checklist's post-upgrade checks: `VERSION()` returns the release, the owner is unchanged, the
implementation is still the dispatcher and the pending plan is empty. `josuke accept` confirms on chain that every
proposed selector routes to its module, and moves `proposed` to `current`. Commit that to the fork.

### 7. Check the stages

Run `make smoke STAGE=dev`, `STAGE=staging` and `STAGE=prod`, and infra-nodes' `test-nodes` workflow for each node.
A data set that gains pieces and records a proof after an upload shows the full path works. Piri submits pieces only
once it has buffered `pdp.aggregation.aggregator.min_aggregate_size` (128 MiB by default), and waits
`pdp.aggregation.commp.delay` (one hour by default) before computing a piece's commitment. Both can be lowered on a
running Piri for a test with `piri client admin config set`, and set back after.

### Recovery

Decide how to recover before the announcement, and record the decision in the fork's pull request. A migration that
ran cannot be reversed in one call: recovery is another migration, under the same delay. Routing back to the previous
`current` facets is safe only when the release leaves storage as the old code reads it. A release whose migration
writes storage the old facets would misread needs either a reverse migration, reviewed and run on smelt like the
forward one, or a decision to fix forward. One migration moves dev, staging and prod together, so a bad recovery
reaches all three.

## Path B: deploy a fresh proxy and reset a stage onto it

Not for production. The prod reset tooling refuses it, and prod's data would be lost.

Path B moved dev and staging off the shared proxy prod used before, `0x0c6875983B20901a7C3c86871f43FdEE77946424`,
which Forge does not own. It applies again only if a release cannot be applied in place, or a stage has to start over
on a proxy of its own.

### 1. Deploy the proxy

From `service_contracts/` in a checkout of the release commit, simulate first. The simulation broadcasts nothing and
prints the proxy address the deploy will produce at the deployer's current nonce:

```bash
FILECOIN_PAY_ADDRESS=0x09a0fDc2723fAd1A7b8e3e00eE5DF73841df55a0 \
PDP_VERIFIER_PROXY_ADDRESS=0x85e366Cf9DD2c0aE37E963d9556F5f4718d6417C \
SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS=0x839e5c9988e4e9977d40708d0094103c0839Ac9D \
SESSION_KEY_REGISTRY_ADDRESS=0x518411c2062E119Aaf7A8B12A2eDf9a939347655 \
USDFC_TOKEN_ADDRESS=0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0 \
FILBEAM_BENEFICIARY_ADDRESS=0x1D60d2F5960Af6341e842C539985FA297E10d6eA \
FILBEAM_CONTROLLER_ADDRESS=0x5f7E5E2A756430EdeE781FF6e6F7954254Ef629A \
MAX_PROVING_PERIOD=20 CHALLENGE_WINDOW_SIZE=5 SKIP_UPDATE_DEPLOYMENTS=true \
forge script script/FWSSDeploy.s.sol \
  --rpc-url https://api.calibration.node.glif.io/rpc/v1 \
  --sender <deployer address>
```

To deploy, add `--account <keystore name> --broadcast --skip-simulation`. Without `--skip-simulation`, forge sets
each gas limit from its local EVM, and the node rejects the first transaction ("'GasLimit' field cannot be less than
the cost of storing a message on chain"). The deploy sends one transaction per contract, 19 for 1.6.0. If it stops
partway, do not run it again: a second run starts at the next nonce and deploys every contract at new addresses.
Forge reads the script path relative to the working directory, and from the repository root fails with "contract
source info format must be `<path>:<contractname>`".

Check the new proxy with read-only calls: `VERSION()`, `owner()`, the ERC-1967 implementation slot (the dispatcher),
`viewContractAddress()` (the proxy itself, so `FWSS_VIEW_ADDRESS` is the proxy address), `getPDPConfig()` and every
dependency getter. Record the proxy in the fork's `josuke.json`, or path A cannot upgrade it later.

### 2. Point central at it

Change `chain.contracts.fwss` in `terraform/envs/<stage>/platform/terraform.tfvars` and let the stage's apply finish
before the reset. The apply changes the provision Lambda's `FORGE_FWSS_ADDRESS`, then the delegator's and the signing
service's.

### 3. Approve the new FWSS as the payer's operator

```bash
make fund-payer STAGE=<stage> \
  FUND_ARGS="--lockup-allowance <cap> --rate-allowance <cap> --max-lockup-period <epochs> --force-deposit"
```

Copy all three limits of the payer's approval for the FWSS it leaves, which FilecoinPay's
`operatorApprovals(token, payer, operator)` returns: the rate and lockup allowances and the maximum lockup period.
The defaults (3 USDFC lockup, 0.1 USDFC per epoch, 86,400 epochs) suit dev only, and a shorter period than the old
approval's can make new proof sets fail to lock up. Each new proof set locks about 0.9 USDFC. The old proof sets keep their lockup, and the fund phase
skips the deposit whenever the account's total funds exceed it, so pass `--force-deposit` when little of that total is
available. The script prints its plan and asks before it signs.

### 4. Reset the node, then central

Follow [reset-apps.md](reset-apps.md) steps 1 and 2. Dev's node has no SSH; run its reset through Systems Manager
with `aws ssm send-command` and `scripts/host/reset-apps.sh --yes`.

### 5. Point the node at it

Merge the change to `FWSS_ADDRESS` and `FWSS_VIEW_ADDRESS` in infra-nodes' `nodes/<node>/node.env` as soon as central
reports the stage up. The reconcile pass that follows starts each Piri against the new FWSS, and `piri init` creates
its proof set there. Merged before the node reset, it starts Piri against the new FWSS with the old proof set in its
database. An image bump that merges between the node reset and this change starts Piri on the old FWSS. Keep the
window short and watch infra-nodes' open pull requests during it.

### 6. Onboard and verify

Continue from step 5 of [reset-apps.md](reset-apps.md): onboard each Piri with the command
`scripts/host/onboarding-request.sh` prints, reset FilOne's tenants for the region with
`bin/reset-region-provisioning.ts`, and run `make smoke STAGE=<stage>`. Each Piri keeps its keys and wallet, so its
provider registration is reused and its wallet needs no funding. Check that each new proof set has the new FWSS as its
listener, then that it gains pieces and records a proof, as in path A step 7.
