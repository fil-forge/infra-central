#!/usr/bin/env bash
# Wipe the app state central holds for a dev or staging stage, and keep the
# platform: the RDS instance and its roles, OpenBao, every identity and wallet.
#
# Run it when a stage has to forget its appliances, for example after a node is
# rebuilt with new Piris. Reset the node first with infra-nodes'
# scripts/host/reset-apps.sh, so nothing on it writes to central while this
# runs. docs/reset-apps.md has the whole order, onboarding included.
#
# What it wipes:
#   - the sprue, hilt, swarf and plc databases, dropped and recreated empty
#   - hilt's tenant secrets in OpenBao
#   - the delegator's allow list and provider-info tables, emptied
#   - sprue's buckets, every object version included
#   - each appliance region's recorded Piri DIDs in SSM
#
# The databases and OpenBao are private to the VPC, so the provision Lambda's
# reset-apps phase wipes those. The rest is done here with the aws CLI.
#
# Steps, in order:
#   1. ask the Lambda what it would wipe, and print it with the AWS stores
#   2. after you approve it, scale the app services to zero
#   3. run the reset-apps phase
#   4. empty the tables, the buckets and the Piri records
#   5. scale the app services back up and wait until they are stable
#
# A run that fails partway can be repeated from the start. If it stops after
# step 2, the app services stay at zero until a rerun or the next apply.
#
# Usage:
#   scripts/reset-apps.sh --stage dev
#
# Options:
#   --stage    stage to reset, dev or staging             (default: dev)
#   --yes      skip the interactive prompt
#
# Prerequisites:
#   - AWS credentials for the account holding the stage
set -euo pipefail

STAGE="${STAGE:-dev}"
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --stage)   STAGE="$2"; shift 2 ;;
    --yes|-y)  ASSUME_YES=true; shift ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# The Lambda refuses other stages too. Checking here as well fails before the
# script scales anything down.
case "$STAGE" in
  dev|staging) ;;
  *) echo "ERROR: refusing to reset stage '$STAGE'; only dev and staging can be reset" >&2; exit 2 ;;
esac

command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found in PATH" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="$ROOT/terraform/envs/$STAGE/platform/terraform.tfvars"
[ -f "$TFVARS" ] || { echo "ERROR: no such stage '$STAGE': $TFVARS does not exist" >&2; exit 1; }

# The regions whose Piri records are deleted: every label in appliance_regions.
# The assignment may span several lines, as HCL allows, so everything from the
# name up to the closing bracket is read, comments dropped, before the labels
# are picked out. A while-read loop rather than mapfile, which the bash 3.2
# macOS ships lacks.
regions_hcl="$(awk '
  /^[[:space:]]*appliance_regions[[:space:]]*=/ { found = 1; sub(/^[^=]*=/, "") }
  found { sub(/#.*/, ""); print; if (/\]/) exit }
' "$TFVARS")"
[ -n "$regions_hcl" ] || { echo "ERROR: no appliance_regions in $TFVARS" >&2; exit 1; }

REGIONS=()
while IFS= read -r region; do
  REGIONS+=("$region")
done < <(grep -o '"[^"]*"' <<<"$regions_hcl" | tr -d '"')

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
CLUSTER="fc-${STAGE}"
FUNCTION="fc-${STAGE}-provision"
SERVICES=(sprue hilt swarf plc delegator)
TABLES=("fc-${STAGE}-delegator-allow-list" "fc-${STAGE}-delegator-provider-info")
BUCKETS=("fc-${STAGE}-agent-message-${ACCOUNT}" "fc-${STAGE}-delegation-${ACCOUNT}")

# invoke <confirm> — call the reset-apps phase and print its JSON response. A
# Lambda error is reported as a successful invocation with FunctionError set, so
# that is checked separately.
#
# Every failure has to become an explicit return: bash drops errexit inside
# command substitution, and the callers read this function through one.
invoke() {
  local confirm="$1" payload response out
  payload="$(jq -nc --argjson confirm "$confirm" '{phase:"reset-apps", confirm:$confirm}')"

  out="$(mktemp)" || return 1
  trap 'rm -f "$out"' RETURN

  if ! response="$(aws lambda invoke \
    --function-name "$FUNCTION" \
    --cli-binary-format raw-in-base64-out \
    --payload "$payload" \
    --cli-read-timeout 900 \
    "$out")"; then
    echo "ERROR: aws lambda invoke failed" >&2
    return 1
  fi

  if [ "$(jq -r '.FunctionError // empty' <<<"$response")" != "" ]; then
    echo "ERROR: the reset-apps phase failed:" >&2
    jq -r '.errorMessage // .' "$out" >&2
    return 1
  fi

  cat "$out"
}

# scale <count> — set every app service's desired count.
scale() {
  local count="$1" service
  for service in "${SERVICES[@]}"; do
    aws ecs update-service --cluster "$CLUSTER" --service "${CLUSTER}-${service}" \
      --desired-count "$count" --query 'service.serviceName' --output text >/dev/null
  done
}

# wait_stable — wait until every service in the cluster runs its desired count
# of tasks: none for the app services after scaling down, one after scaling
# back up. The repository's waiter rather than aws ecs wait, whose budget is a
# fixed ten minutes and whose timeout names no service.
wait_stable() {
  "$ROOT/scripts/wait-services-stable.sh" "$CLUSTER"
}

# empty_table <table> — delete every item, a page of 25 at a time, which is the
# most one BatchWriteItem takes. The table itself stays, so this works under
# deletion protection. Items the batch leaves unprocessed reappear in the next
# scan.
empty_table() {
  local table="$1" key page requests deleted=0
  key="$(aws dynamodb describe-table --table-name "$table" \
    --query "Table.KeySchema[?KeyType=='HASH'].AttributeName | [0]" --output text)"

  while :; do
    page="$(aws dynamodb scan --table-name "$table" \
      --projection-expression '#k' --expression-attribute-names "{\"#k\":\"$key\"}" \
      --consistent-read --max-items 25 --output json)"
    [ "$(jq '.Items | length' <<<"$page")" -gt 0 ] || break

    requests="$(jq -c --arg table "$table" \
      '{($table): [.Items[] | {DeleteRequest: {Key: .}}]}' <<<"$page")"
    aws dynamodb batch-write-item --request-items "$requests" >/dev/null
    deleted=$((deleted + $(jq '.Items | length' <<<"$page")))
  done
  echo "  ✓ emptied $table ($deleted item(s))"
}

# purge_bucket <bucket> — delete every object version and delete marker, a page
# of up to 1000 at a time. Staging's buckets are versioned, and aws s3 rm would
# only stack delete markers on top of the old versions. An unversioned bucket
# lists each object once, with version ID "null", so the same call covers dev.
purge_bucket() {
  local bucket="$1" page objects count deleted=0
  while :; do
    page="$(aws s3api list-object-versions --bucket "$bucket" --max-items 1000 --output json)"
    objects="$(jq -c '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key, VersionId})), Quiet: true}' <<<"$page")"
    count="$(jq '.Objects | length' <<<"$objects")"
    [ "$count" -gt 0 ] || break

    aws s3api delete-objects --bucket "$bucket" --delete "$objects" \
      --query 'Errors' --output json | jq -e 'length == 0' >/dev/null \
      || { echo "ERROR: some objects in $bucket could not be deleted" >&2; return 1; }
    deleted=$((deleted + count))
  done
  echo "  ✓ purged $bucket ($deleted version(s))"
}

# delete_piri_records <region> — delete the region's Piri DIDs, ten names per
# call, which is what DeleteParameters takes. The rest of the region's prefix
# stays: its unseal-token accessor and the stored hilt delegation.
delete_piri_records() {
  local region="$1" path listing name names
  path="/forge-central/${STAGE}/appliance/${region}/piri"
  # Listed into a variable first: a failure inside a process substitution
  # escapes set -e, and the region would be reported as having no records.
  listing="$(aws ssm get-parameters-by-path --path "$path" --recursive \
    --query 'Parameters[].Name' --output text)"

  names=()
  while IFS= read -r name; do
    names+=("$name")
  done < <(tr '\t' '\n' <<<"$listing" | sed -e '/^None$/d' -e '/^$/d')

  # The loop body never runs for an empty list, which matters: bash 3.2 under
  # set -u reports an empty array's expansion as an unbound variable.
  local i
  for ((i = 0; i < ${#names[@]}; i += 10)); do
    aws ssm delete-parameters --names "${names[@]:i:10}" >/dev/null
  done
  echo "  ✓ deleted ${#names[@]} Piri record(s) for $region"
}

echo "=== Reset the apps of ${STAGE} ==="
echo "  Lambda:  $FUNCTION"
echo "  Cluster: $CLUSTER"
echo

echo "[1/5] Reading what the Lambda would wipe (nothing is changed yet)…"
plan="$(invoke false)"

jq -r '
  .reset_apps_plan as $p |
  "  databases to drop and recreate: \(if ($p.databases | length) == 0 then "none" else ($p.databases | join(", ")) end)",
  "  hilt secrets to destroy:        \($p.hilt_secrets)"
' <<<"$plan"
echo "  tables to empty:                ${TABLES[*]}"
echo "  buckets to purge:               ${BUCKETS[*]}"
echo "  regions to forget Piris for:    ${REGIONS[*]+${REGIONS[*]}}"
echo "  services scaled to zero:        ${SERVICES[*]}"
echo

echo "This is permanent. Every tenant, bucket, access key, upload and registered"
echo "Piri in ${STAGE} goes. Each appliance has to be onboarded again afterwards."
echo

if [ "$ASSUME_YES" != true ]; then
  read -r -p "Type 'reset-${STAGE}' to proceed: " reply
  [ "$reply" = "reset-${STAGE}" ] || { echo "Aborted; nothing was changed."; exit 1; }
  echo
fi

# From here on, a failure can leave the app services at zero. An EXIT trap
# rather than ERR, because ERR does not reach into the functions above.
finished=false
trap '[ "$finished" = true ] || {
  echo >&2
  echo "ERROR: the reset stopped partway, and the app services may still be at zero." >&2
  echo "Rerun scripts/reset-apps.sh --stage ${STAGE} to finish." >&2
}' EXIT

echo "[2/5] Scaling ${SERVICES[*]} to zero…"
scale 0
wait_stable
echo "  ✓ no app task is running"

echo "[3/5] Running the reset-apps phase…"
result="$(invoke true)"
jq -r '
  .reset_apps_result as $r |
  "  ✓ dropped:   \(if ($r.dropped | length) == 0 then "none" else ($r.dropped | join(", ")) end)",
  "  ✓ recreated: \($r.recreated | join(", "))",
  "  ✓ destroyed \($r.hilt_secrets_destroyed) hilt secret(s)"
' <<<"$result"

echo "[4/5] Emptying the stores outside the VPC…"
for table in "${TABLES[@]}"; do empty_table "$table"; done
for bucket in "${BUCKETS[@]}"; do purge_bucket "$bucket"; done
for region in ${REGIONS[@]+"${REGIONS[@]}"}; do delete_piri_records "$region"; done

echo "[5/5] Scaling the app services back up…"
scale 1
wait_stable
echo "  ✓ every app service is running again"
finished=true

echo
echo "Done. Each service migrated its empty database on start. Next, deploy the"
echo "appliance and onboard each of its Piris with scripts/onboard-appliance.sh;"
echo "docs/reset-apps.md has the order."
