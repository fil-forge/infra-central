#!/usr/bin/env bash
# Check that a region's backup writer can do what WAL-G and the raft snapshot
# upload need and nothing else, and that the stage's backup bucket keeps what it
# is given.
#
# Run it with administrator credentials for the stage's account. It creates a
# temporary second access key on the region's writer user, acts as that writer,
# and deletes the key however the script ends. The writer's real key, held by
# the node, is never touched.
#
# Every run leaves a few small objects under <region>/check/ and
# <region>/postgres/check/. They are locked in compliance mode like any backup,
# so nothing can delete them early; they expire 36 days after the run.
#
# Usage:
#   scripts/check-appliance-backup-access.sh staging eu-central-3
#
# Options:
#   --retention-days  the lock the bucket should apply  (default: 35)
#
# Prerequisites:
#   - administrator credentials for the account holding the stage
#   - the region's writer user, created by the apply from appliance_regions
set -euo pipefail

RETENTION_DAYS=35
positional=()

while [ $# -gt 0 ]; do
  case "$1" in
    --retention-days) RETENTION_DAYS="$2"; shift 2 ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  positional+=("$1"); shift ;;
  esac
done

[ "${#positional[@]}" -eq 2 ] || { echo "usage: $0 <stage> <region>" >&2; exit 2; }
STAGE="${positional[0]}"
REGION="${positional[1]}"

command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found in PATH" >&2; exit 1; }

# The bucket lives in the stage's home region, like everything else central runs.
export AWS_REGION="${AWS_REGION:-us-east-2}"

account="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="forge-nodes-backups-${STAGE}-${account}"
WRITER="forge-nodes-backup-${STAGE}-${REGION}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

WORK="$(umask 077; mktemp -d)"
KEY_ID=""

cleanup() {
  if [ -n "$KEY_ID" ]; then
    if aws iam delete-access-key --user-name "$WRITER" --access-key-id "$KEY_ID"; then
      echo "Deleted the temporary access key $KEY_ID."
    else
      echo "ERROR: could not delete the temporary access key $KEY_ID of $WRITER." >&2
      echo "Delete it by hand: aws iam delete-access-key --user-name $WRITER --access-key-id $KEY_ID" >&2
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

echo "=== Check the ${REGION} backup writer on ${STAGE} ==="
echo "  Bucket:  $BUCKET"
echo "  Writer:  $WRITER"
echo

# --- 1. A temporary key for the writer --------------------------------------

# The secret stays in shell variables and reaches the AWS CLI through exported
# variables in a subshell, never through anything's argv.
if ! created="$(aws iam create-access-key --user-name "$WRITER" --output json)"; then
  echo "ERROR: could not create a temporary key on $WRITER. IAM allows two keys per" >&2
  echo "user, so a user that already has two needs one deleted first." >&2
  exit 1
fi
KEY_ID="$(jq -r '.AccessKey.AccessKeyId' <<<"$created")"
WRITER_SECRET="$(jq -r '.AccessKey.SecretAccessKey' <<<"$created")"
unset created
echo "Created the temporary access key $KEY_ID."
echo

as_writer() {
  (
    unset AWS_PROFILE AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
    export AWS_ACCESS_KEY_ID="$KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$WRITER_SECRET"
    aws "$@"
  )
}

passed=0
failed=0

pass() { passed=$((passed + 1)); printf '  PASS  %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }

# expect_ok <name> <command...> — the command succeeds.
expect_ok() {
  local name="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    pass "$name"
  else
    fail "$name" "$(head -1 <<<"$out")"
  fi
}

# expect_denied <name> <command...> — the command is refused with AccessDenied.
expect_denied() {
  local name="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    fail "$name" "succeeded, and must not"
  elif grep -q 'AccessDenied' <<<"$out"; then
    pass "$name"
  else
    fail "$name" "failed for a reason other than AccessDenied: $(head -1 <<<"$out")"
  fi
}

printf 'backup check %s\n' "$STAMP" >"$WORK/body"

# Object Lock refuses a put without Content-MD5 or a checksum header. AWS CLI v2
# sends a checksum by default; naming one keeps an older CLI from failing here
# for that reason instead of the one under test.
put() {
  as_writer s3api put-object --bucket "$BUCKET" --key "$1" --body "$WORK/body" \
    --checksum-algorithm CRC32 --output json
}

object="$REGION/check/$STAMP"
history="$REGION/postgres/check/$STAMP.history"

# --- 2. What the writer must be able to do ----------------------------------

echo "As the writer, expecting success:"

# A new key takes a few seconds to be accepted everywhere, so the first call is
# retried until it is.
version=""
for attempt in $(seq 1 20); do
  if out="$(put "$object" 2>&1)"; then
    version="$(jq -r '.VersionId // empty' <<<"$out")"
    break
  fi
  if [ "$attempt" -eq 20 ] || ! grep -q 'InvalidAccessKeyId\|SignatureDoesNotMatch' <<<"$out"; then
    break
  fi
  sleep 3
done
if [ -n "$version" ]; then
  pass "put $object"
else
  fail "put $object" "$(head -1 <<<"$out")"
fi

expect_ok "put $history" put "$history"
expect_ok "get $history" as_writer s3api get-object --bucket "$BUCKET" --key "$history" "$WORK/history"

# WAL-G reads a history file before uploading one, and treats 404 as "not there
# yet". Without ListBucket S3 answers 403 instead, which WAL-G treats as fatal,
# so this is the check that the prefix-conditioned ListBucket is enough.
missing="$REGION/postgres/check/missing.history"
if out="$(as_writer s3api get-object --bucket "$BUCKET" --key "$missing" "$WORK/missing" 2>&1)"; then
  fail "get missing $missing returns 404" "the object exists"
elif grep -q 'NoSuchKey' <<<"$out"; then
  pass "get missing $missing returns 404"
elif grep -q 'AccessDenied' <<<"$out"; then
  fail "get missing $missing returns 404" "got 403, so WAL-G would fail on its first history upload; the s3:prefix condition on ListBucket does not cover this read"
else
  fail "get missing $missing returns 404" "$(head -1 <<<"$out")"
fi

expect_ok "list $REGION/" as_writer s3api list-objects-v2 --bucket "$BUCKET" --prefix "$REGION/" --max-items 1
echo

# --- 3. What the writer must not be able to do ------------------------------

echo "As the writer, expecting AccessDenied:"
expect_denied "get $object" as_writer s3api get-object --bucket "$BUCKET" --key "$object" "$WORK/object"
expect_denied "delete $object" as_writer s3api delete-object --bucket "$BUCKET" --key "$object"
if [ -n "$version" ]; then
  expect_denied "delete $object version $version" \
    as_writer s3api delete-object --bucket "$BUCKET" --key "$object" --version-id "$version"
else
  fail "delete $object by version" "no version to try, since the put failed"
fi
expect_denied "put check-other/$STAMP" put "check-other/$STAMP"
expect_denied "list check-other/" as_writer s3api list-objects-v2 --bucket "$BUCKET" --prefix "check-other/" --max-items 1
echo

# --- 4. What the bucket keeps -----------------------------------------------

echo "As the administrator:"
expect_ok "get $object" aws s3api get-object --bucket "$BUCKET" --key "$object" "$WORK/object"

if retention="$(aws s3api get-object-retention --bucket "$BUCKET" --key "$object" --output json 2>&1)"; then
  mode="$(jq -r '.Retention.Mode' <<<"$retention")"
  until_epoch="$(jq -r '.Retention.RetainUntilDate | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601' <<<"$retention")"
  expected_epoch=$(( $(date -u +%s) + RETENTION_DAYS * 86400 ))
  drift=$(( until_epoch - expected_epoch ))
  if [ "$mode" = COMPLIANCE ] && [ "${drift#-}" -le 3600 ]; then
    pass "$object is locked in COMPLIANCE mode for $RETENTION_DAYS days"
  else
    fail "$object retention" "mode $mode, until $(jq -r '.Retention.RetainUntilDate' <<<"$retention")"
  fi
else
  fail "$object retention" "$(head -1 <<<"$retention")"
fi

lock="$(aws s3api get-object-lock-configuration --bucket "$BUCKET" --output json 2>&1 || true)"
lock_summary="$(jq -c '.ObjectLockConfiguration | {enabled: .ObjectLockEnabled, mode: .Rule.DefaultRetention.Mode, days: .Rule.DefaultRetention.Days}' <<<"$lock" 2>/dev/null || true)"
lock_expected="$(jq -nc --argjson days "$RETENTION_DAYS" '{enabled: "Enabled", mode: "COMPLIANCE", days: $days}')"
if [ "$lock_summary" = "$lock_expected" ]; then
  pass "bucket Object Lock is $lock_expected"
else
  fail "bucket Object Lock" "got ${lock_summary:-$(head -1 <<<"$lock")}, want $lock_expected"
fi

lifecycle="$(aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --output json 2>&1 || true)"
lifecycle_summary="$(jq -c '[.Rules[] | select(.Status == "Enabled") | {
    id: .ID,
    expiration_days: .Expiration.Days,
    expired_object_delete_marker: .Expiration.ExpiredObjectDeleteMarker,
    noncurrent_days: .NoncurrentVersionExpiration.NoncurrentDays,
    abort_days: .AbortIncompleteMultipartUpload.DaysAfterInitiation
  } | with_entries(select(.value != null))] | sort_by(.id)' <<<"$lifecycle" 2>/dev/null || true)"
lifecycle_expected="$(jq -nc --argjson days "$RETENTION_DAYS" '[
    {id: "abort-incomplete-uploads", abort_days: 7},
    {id: "delete-noncurrent-versions", noncurrent_days: 1},
    {id: "expire-backups", expiration_days: $days},
    {id: "remove-expired-delete-markers", expired_object_delete_marker: true}
  ]')"
if [ "$lifecycle_summary" = "$lifecycle_expected" ]; then
  pass "bucket lifecycle has the four expected rules"
else
  fail "bucket lifecycle" "got ${lifecycle_summary:-$(head -1 <<<"$lifecycle")}, want $lifecycle_expected"
fi
echo

unset WRITER_SECRET

echo "$passed passed, $failed failed."
echo "This run left small locked objects under $REGION/check/ and $REGION/postgres/check/;"
echo "they expire 36 days from now and cannot be deleted before."
[ "$failed" -eq 0 ]
