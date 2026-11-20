# Moving a stage to a new FWSS release

Dev and staging move to a new FilecoinWarmStorageService (FWSS) release by deploying a fresh FWSS
proxy on Calibration and resetting the stage onto it. The FWSS proxy dev and staging used before
sc-1077, `0x0c6875983B20901a7C3c86871f43FdEE77946424`, is shared with prod and owned by a key Forge
does not hold, so it is never upgraded in place. A fresh proxy costs each Piri its stored blobs and
its old proof set: a proof set cannot move to another FWSS, because PDPVerifier records its FWSS as
the listener when the set is created.

Prod is out of scope. `make reset-apps` refuses it.

The run that moved dev to FWSS 1.6.0 is the worked example throughout.

## 1. Merge the release into the fork

FWSS is built from [fil-forge/filecoin-services](https://github.com/fil-forge/filecoin-services), a
fork of FilOzone's repository. Merge the upstream release tag into the fork's `main` in a pull
request; [#6](https://github.com/fil-forge/filecoin-services/pull/6) merged v1.6.0. Before merging,
check that the release still accepts the payloads Piri and the signing service send. 1.6.0 accepts
the five-field `dataSetCreated` payload and the `CreateDataSet` EIP-712 type and maps both to storage
terms record 0, so neither needed a change.

The pull request's `smoke-test` jobs build the localdev image and fail if forge compiles at container
start. Merging to `main` publishes the image as `ghcr.io/fil-forge/filecoin-localdev:<commit>`.

## 2. Move smelt to the new image

Smelt's local chain boots from a baseline the localdev image produced, so the image and the
baseline move together. `systems/blockchain/README.md` in smelt has the steps. A fresh deploy moves
the FWSS address, so the configs that name it change in the same pull request
([smelt#88](https://github.com/fil-forge/smelt/pull/88)).

Recapture `snapshots/3-piri-postgres-s3` from a stack started under a compose project name no other
stack uses, with `COMPOSE_PROJECT_NAME` exported for both `make up` and `smelt snapshot save`. A stack
started as `smelt` reuses any `smelt_*` volumes already on the machine, and `snapshot save` looks for
volumes under the directory name, so a save from a worktree without that variable writes empty
archives and reports success.

## 3. Deploy FWSS on Calibration

Run everything from `service_contracts/` in a checkout of the fork's `main`. Forge reads
`script/FWSSDeploy.s.sol` relative to the working directory, and from the repository root it fails
with "contract source info format must be `<path>:<contractname>`".

Simulate first. The simulation broadcasts nothing and prints the proxy address the deploy will
produce at the deployer's current nonce:

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

The addresses are the shared Calibration contracts dev and staging already use. The script reuses
the ERC-8167 dispatcher recorded in `deployments.json`.

To deploy, add `--account <keystore name> --broadcast --skip-simulation`. Without
`--skip-simulation`, forge sets each gas limit from its local EVM, which charges less than FEVM, and
the node rejects the first transaction ("'GasLimit' field cannot be less than the cost of storing a
message on chain"). Nothing is sent in that case and the deployer's nonce does not move.

The deploy sends one transaction per contract, 19 for 1.6.0, about two Calibration blocks apart.
If it stops partway, do not run it again: a second run starts at the next nonce and deploys every
contract at new addresses.

Check the result with read-only calls on the new proxy:

| Check | Expected |
|---|---|
| `VERSION()` | the release, `"1.6.0"` |
| `owner()` | the deployer |
| storage slot `0x3608…2bbc` (ERC-1967 implementation) | the dispatcher |
| `viewContractAddress()` | the proxy itself |
| `getPDPConfig()` | proving period 20, challenge window 5 |
| `pdpVerifierAddress()`, `paymentsContractAddress()`, `usdfcTokenAddress()`, `serviceProviderRegistry()`, `sessionKeyRegistry()`, `filBeamBeneficiaryAddress()`, `filBeamControllerAddress()` | the inputs above |
| `getStorageTerms(bytes32(0))` | USDFC, 18 decimals, 2.5 USDFC per TiB per month, enabled |

The proxy serves the StateView reads itself, so `FWSS_VIEW_ADDRESS` is the proxy address.

A fresh FWSS has no approved providers. Data set creation does not check approval, so the stage
runs without them.

## 4. Point central at it

Change `chain.contracts.fwss` in `terraform/envs/<stage>/platform/terraform.tfvars`
([#437](https://github.com/fil-forge/infra-central/pull/437) for dev). The platform plan changes the
provision Lambda's `FORGE_FWSS_ADDRESS`, and the apps apply that follows changes the delegator's and
the signing service's. Merge it and let the stage's apply finish before step 6, because a push to
`main` during the reset can start a service while its database is being dropped.

## 5. Fund the payer for the new operator

```bash
make fund-payer STAGE=dev FUND_ARGS=--force-deposit
```

Each new proof set locks about 0.9 USDFC, so dev's three Piri need about 2.7 USDFC available. The
old proof sets keep their lockup, and the fund phase skips the deposit whenever the account's total
funds exceed the deposit, even when almost none of it is available. Dev held 8 USDFC with 0.9
available, so the deposit needed `--force-deposit`. The run also approves the new FWSS as the payer's
operator, which it has to be before any Piri can create a proof set. The script prints the plan and
asks before it signs. If the payer wallet holds less than the deposit, fund it at the
[USDFC faucet](https://forest-explorer.chainsafe.dev/faucet/calibnet_usdfc) first.

## 6. Reset the node, then central

Follow [reset-apps.md](reset-apps.md) steps 1 and 2. On dev, where the node has no SSH, the node's
reset can run through Systems Manager:

```bash
aws ssm send-command --region us-east-2 --instance-ids <dev instance id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cd /opt/fil-one/infra-nodes && scripts/host/reset-apps.sh --yes"]'
```

## 7. Point the node at it

Merge the node's change to `FWSS_ADDRESS` and `FWSS_VIEW_ADDRESS` in infra-nodes'
`nodes/<node>/node.env` ([infra-nodes#339](https://github.com/fil-forge/infra-nodes/pull/339) for
dev) as soon as central's reset reports the stage up. The reconcile pass that follows starts each
Piri against the new FWSS, and `piri init` creates its proof set there. Merged before the node
reset, it starts Piri against the new FWSS with the old proof set in its database. An image bump that
merges between the node reset and this change starts Piri on the old FWSS, where it creates a proof
set the stage cannot use. Keep that window short and watch infra-nodes' open pull requests during it.

## 8. Onboard and verify

Continue from step 5 of [reset-apps.md](reset-apps.md): onboard each Piri with the command
`scripts/host/onboarding-request.sh` prints on the node, reset FilOne's tenants for the region, and
run `make smoke STAGE=<stage>`. The Piri keep their keys and wallets, so their provider
registrations are reused and their owner wallets need no funding.

On chain, each Piri's new proof set should have the new FWSS as its listener, gain pieces after
uploads, and record proofs. Piri submits pieces only once it has buffered
`pdp.aggregation.aggregator.min_aggregate_size` (128 MiB by default), and waits
`pdp.aggregation.commp.delay` (one hour by default) before computing a piece's commitment, so a
small upload shows no pieces for at least an hour.
