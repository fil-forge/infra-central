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
#   - every Piri DID recorded in SSM, in any region
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
# scan. A line after each page shows the running total.
empty_table() {
  local table="$1" key page requests deleted=0
  echo "  emptying ${table}…"
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
    echo "    deleted $deleted item(s) so far"
  done
  echo "  ✓ emptied $table ($deleted item(s))"
}

# purge_bucket <bucket> — delete every object version and delete marker, a page
# of up to 1000 at a time. Staging's buckets are versioned, and aws s3 rm would
# only stack delete markers on top of the old versions. An unversioned bucket
# lists each object once, with version ID "null", so the same call covers dev.
# A bucket with a long history takes minutes, so a line after each page shows
# the running total.
purge_bucket() {
  local bucket="$1" page objects count deleted=0
  echo "  purging ${bucket}…"
  while :; do
    # One service page, whose MaxKeys bounds versions and delete markers
    # together. The CLI's --max-items counts only versions and can return more
    # than DeleteObjects takes, so the slice below is a second bound.
    page="$(aws s3api list-object-versions --bucket "$bucket" \
      --no-paginate --max-keys 1000 --output json)"
    objects="$(jq -c '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key, VersionId}) | .[:1000]), Quiet: true}' <<<"$page")"
    count="$(jq '.Objects | length' <<<"$objects")"
    [ "$count" -gt 0 ] || break

    aws s3api delete-objects --bucket "$bucket" --delete "$objects" \
      --query 'Errors' --output json | jq -e 'length == 0' >/dev/null \
      || { echo "ERROR: some objects in $bucket could not be deleted" >&2; return 1; }
    deleted=$((deleted + count))
    echo "    deleted $deleted version(s) and delete marker(s) so far"
  done
  echo "  ✓ purged $bucket ($deleted version(s))"
}

# list_piri_records — print every Piri record the stage holds, one name per
# line, in whichever region it was recorded.
#
# Read from SSM rather than from appliance_regions in the tfvars: the records
# are what has to go, and a region dropped from the list may still hold some.
# Only names under a region's piri/ go. The rest of each region's prefix stays:
# its unseal-token accessor and the stored hilt delegation.
#
# Callers read this through a command substitution, where set -e does not
# reach, so a failed listing returns explicitly rather than reporting a stage
# with no records.
list_piri_records() {
  local listing
  listing="$(aws ssm get-parameters-by-path --path "/forge-central/${STAGE}/appliance" \
    --recursive --query 'Parameters[].Name' --output text)" || return 1
  tr '\t' '\n' <<<"$listing" | grep -E "^/forge-central/${STAGE}/appliance/[^/]+/piri/" || true
}

# delete_piri_records — delete every Piri record, ten names per call, which is
# what DeleteParameters takes.
delete_piri_records() {
  local listing name names=()
  listing="$(list_piri_records)"
  while IFS= read -r name; do
    [ -n "$name" ] && names+=("$name")
  done <<<"$listing"

  # The loop body never runs for an empty list, which matters: bash 3.2 under
  # set -u reports an empty array's expansion as an unbound variable.
  local i
  for ((i = 0; i < ${#names[@]}; i += 10)); do
    aws ssm delete-parameters --names "${names[@]:i:10}" >/dev/null
  done
  echo "  ✓ deleted ${#names[@]} Piri record(s)"
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
piri_records="$(list_piri_records)"
echo "  Piri records to delete:         $(grep -c . <<<"$piri_records" || true)"
sed -e '/^$/d' -e 's|^|    |' <<<"$piri_records"
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
  echo "Rerun make reset-apps STAGE=${STAGE} to finish; make supplies the AWS region." >&2
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
delete_piri_records

echo "[5/5] Scaling the app services back up…"
scale 1
wait_stable
echo "  ✓ every app service is running again"
finished=true

echo
echo "Done. Each service migrated its empty database on start. Next, deploy the"
echo "appliance and onboard each of its Piris with scripts/onboard-appliance.sh;"
echo "docs/reset-apps.md has the order."
