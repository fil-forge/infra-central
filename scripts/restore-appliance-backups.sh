#!/usr/bin/env bash
# Copy a region's backups, as they stood at a cutoff time, to a fresh prefix of
# the same bucket, where WAL-G and an OpenBao raft restore can read them with
# plain gets.
#
# Run it when the region's backup writer key may have leaked. Such a key cannot
# delete a backup, but it can put an object at an existing key, which becomes
# the version a plain GetObject reads, or at a new key, which a restore that
# lists the prefix picks up. S3 sets each version's LastModified itself, so a
# version written before the leak carries a time before it. For every key under
# <region>/, this copies the latest version written before the cutoff to
#
#   restores/<region>/<cutoff>/<the key without its region prefix>
#
# A key first written at or after the cutoff is left out, and so is a key whose
# latest entry before the cutoff is a lifecycle delete marker, because it had
# expired by then. What lands under the target is the region's prefix as a
# listing at the cutoff would have shown it.
#
# S3 lists one second of precision, so a key whose latest version and a delete
# marker share the last second before the cutoff has no knowable order. Such a
# key is left out and listed in the plan, for an engineer to decide.
#
# A multipart object's LastModified is when its upload started, so an upload the
# node started before the cutoff and completed after it counts as written before
# the cutoff. Its parts are still the node's: the writer key cannot list
# in-progress uploads or their parts, so a leaked key cannot find the upload ID
# it would need to add a part or complete the upload.
#
# It reads the region's prefix and writes only under the target. No writer key
# can write there, because each writes only under its own <region>/. The
# bucket's lock and lifecycle apply to the copies as to any backup: they are
# locked for 35 days and gone after 36.
#
# Safe to re-run with the same cutoff. A key already under the target is
# skipped, so an interrupted copy resumes where it stopped.
#
# Usage:
#   scripts/restore-appliance-backups.sh staging eu-central-3 2026-11-05T14:00:00Z
#
# The cutoff is UTC, to the second.
#
# Prerequisites:
#   - administrator credentials for the account holding the stage
#   - the region's backup key deleted or reissued, so no new version lands under
#     <region>/ while the copy runs
#
# See docs/restore-appliance-backups.md for the whole procedure.
set -euo pipefail

# CopyObject copies at most 5 GiB in one request.
MAX_COPY_BYTES=5368709120
PARALLEL_COPIES=16

positional=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  positional+=("$1"); shift ;;
  esac
done

[ "${#positional[@]}" -eq 3 ] || { echo "usage: $0 <stage> <region> <cutoff, e.g. 2026-11-05T14:00:00Z>" >&2; exit 2; }
STAGE="${positional[0]}"
REGION="${positional[1]}"
CUTOFF="${positional[2]}"

if ! [[ "$REGION" =~ ^[a-z0-9][a-z0-9-]*$ ]] || [ "$REGION" = restores ]; then
  echo "ERROR: '$REGION' is not a region label." >&2
  exit 2
fi
if ! [[ "$CUTOFF" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  echo "ERROR: the cutoff '$CUTOFF' is not a UTC time like 2026-11-05T14:00:00Z." >&2
  exit 2
fi

command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found in PATH" >&2; exit 1; }

# jq rolls an impossible date such as 2026-02-30 over into the next month, so a
# cutoff that does not survive the round trip is not a real time.
jq -e -n --arg cutoff "$CUTOFF" '$cutoff | fromdateiso8601 | todateiso8601 == $cutoff' >/dev/null \
  || { echo "ERROR: the cutoff '$CUTOFF' is not a valid time." >&2; exit 2; }

# A cutoff in the future would take every current version, forged ones included.
if [ "$(jq -n --arg cutoff "$CUTOFF" '$cutoff | fromdateiso8601')" -gt "$(date -u +%s)" ]; then
  echo "ERROR: the cutoff '$CUTOFF' is in the future." >&2
  exit 2
fi

# The bucket lives in the stage's home region, like everything else central runs.
export AWS_REGION="${AWS_REGION:-us-east-2}"

account="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="forge-nodes-backups-${STAGE}-${account}"
SOURCE_PREFIX="${REGION}/"
TARGET_PREFIX="restores/${REGION}/${CUTOFF//[-:]/}/"

# Kept after the script ends: the plan and manifest record what was restored.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/restore-appliance-backups.XXXXXX")"

echo "=== Restore ${REGION}'s backups on ${STAGE} as of ${CUTOFF} ==="
echo "  Bucket:  $BUCKET"
echo "  From:    $SOURCE_PREFIX"
echo "  To:      $TARGET_PREFIX"
echo "  Records: $WORK"
echo

# --- 1. Read the versions and pick one per key ------------------------------

echo "Listing every version under $SOURCE_PREFIX ..."
aws s3api list-object-versions --bucket "$BUCKET" --prefix "$SOURCE_PREFIX" --output json \
  >"$WORK/versions.json"
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$TARGET_PREFIX" \
  --query 'Contents[].Key' --output json >"$WORK/already-copied.json"

# The CLI prints nothing, or null, for an empty listing.
[ -s "$WORK/versions.json" ] || echo '{}' >"$WORK/versions.json"
[ -s "$WORK/already-copied.json" ] || echo 'null' >"$WORK/already-copied.json"

# plan.json holds one entry per key in four lists: copy, after_cutoff, expired
# and ambiguous. A copy entry counts the versions written at or after the cutoff
# that stand in front of the chosen one.
#
# Versions of one key are listed newest first, so their position breaks a tie
# between two versions written in the same second. Delete markers come in a
# list of their own, which says nothing about their order against versions.
jq --arg cutoff "$CUTOFF" --arg source "$SOURCE_PREFIX" --arg target "$TARGET_PREFIX" \
  --slurpfile already "$WORK/already-copied.json" '
  def epoch:
    sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
  def encode_path: split("/") | map(@uri) | join("/");

  ($cutoff | fromdateiso8601) as $cutoff_epoch
  | (($already[0] // []) | map({key: ., value: true}) | from_entries) as $copied
  | [ (.Versions // [] | to_entries[] | .value + {marker: false, position: .key}),
      (.DeleteMarkers // [] | to_entries[] | .value + {marker: true, position: .key}) ]
  | map(. + {epoch: (.LastModified | epoch)})
  | group_by(.Key)
  | map(
      map(select(.epoch < $cutoff_epoch)) as $before
      | ($before | map(.epoch) | max) as $latest_epoch
      | ($before | map(select(.epoch == $latest_epoch))) as $latest
      | {
          key: .[0].Key,
          chosen: ($before | sort_by([.epoch, -.position]) | last),
          ambiguous: (($latest | any(.marker)) and ($latest | any(.marker | not))),
          newer_versions: (map(select(.epoch >= $cutoff_epoch and (.marker | not))) | length)
        })
  | {
      ambiguous: [ .[] | select(.ambiguous) | .key ],
      copy: [ .[] | select(.chosen != null and (.ambiguous | not) and (.chosen.marker | not))
              | ($target + (.key | ltrimstr($source))) as $target_key
              | { key, version_id: .chosen.VersionId, last_modified: .chosen.LastModified,
                  etag: .chosen.ETag, size: .chosen.Size, newer_versions,
                  target: $target_key,
                  copy_source: (.key | encode_path) + "?versionId=" + (.chosen.VersionId | @uri),
                  already_copied: ($copied[$target_key] // false) } ],
      after_cutoff: [ .[] | select(.chosen == null) | .key ],
      expired: [ .[] | select(.chosen != null and (.ambiguous | not) and .chosen.marker) | .key ]
    }
' "$WORK/versions.json" >"$WORK/plan.json"

jq -r '.copy[] | select(.newer_versions > 0) | "\(.key)\t\(.newer_versions)"' \
  "$WORK/plan.json" >"$WORK/shadowed.tsv"
jq -r '.copy[] | select(.already_copied | not) | "\(.copy_source)\t\(.target)"' \
  "$WORK/plan.json" >"$WORK/manifest.tsv"
jq -r '.ambiguous[]' "$WORK/plan.json" >"$WORK/ambiguous.txt"

read -r to_copy total_gib already_copied too_big after_cutoff expired < <(jq -r --argjson max "$MAX_COPY_BYTES" '
  [ (.copy | length),
    ((.copy | map(.size) | add // 0) / 1073741824 * 10 | round / 10),
    (.copy | map(select(.already_copied)) | length),
    (.copy | map(select(.size > $max)) | length),
    (.after_cutoff | length),
    (.expired | length) ] | @tsv
' "$WORK/plan.json")
shadowed="$(wc -l <"$WORK/shadowed.tsv" | tr -d ' ')"
ambiguous="$(wc -l <"$WORK/ambiguous.txt" | tr -d ' ')"

# --- 2. Show the plan --------------------------------------------------------

echo
echo "  $to_copy keys to copy ($total_gib GiB), $already_copied of them already under the target"
echo "  $after_cutoff keys first written at or after the cutoff, left out"
echo "  $expired keys expired before the cutoff, left out"
echo "  $shadowed of the keys to copy have a version written at or after the cutoff in front"
echo "  of the one copied. A leaked key leaves these, and so does WAL-G when it retries an"
echo "  upload. They are listed in $WORK/shadowed.tsv."
echo
if [ "$ambiguous" -gt 0 ]; then
  echo "  WARNING: $ambiguous keys are left out because their latest version and a delete"
  echo "  marker were written in the same second before the cutoff, so whether the key"
  echo "  existed at the cutoff is unknown. They are listed in $WORK/ambiguous.txt;"
  echo "  copy any you need by hand."
  echo
fi

if [ "$to_copy" -eq 0 ]; then
  echo "ERROR: no version under $SOURCE_PREFIX was written before $CUTOFF." >&2
  exit 1
fi

if [ "$too_big" -gt 0 ]; then
  echo "ERROR: $too_big objects exceed the 5 GiB a single CopyObject can copy:" >&2
  jq -r --argjson max "$MAX_COPY_BYTES" '.copy[] | select(.size > $max) | "  \(.key) (\(.size) bytes)"' \
    "$WORK/plan.json" >&2
  echo "Nothing was copied." >&2
  exit 1
fi

if [ ! -s "$WORK/manifest.tsv" ]; then
  echo "Every key is already under the target."
else
  read -r -p "Type 'copy' to proceed: " reply
  [ "$reply" = "copy" ] || { echo "Aborted; nothing was copied."; exit 1; }
  echo

  # --- 3. Copy -------------------------------------------------------------

  copy_one() {
    local copy_source target out
    IFS=$'\t' read -r copy_source target <<<"$1"
    if ! out="$(aws s3api copy-object --bucket "$BUCKET" --key "$target" \
        --copy-source "$BUCKET/$copy_source" --output json 2>&1 >/dev/null)"; then
      printf 'FAILED  %s: %s\n' "$target" "$(head -1 <<<"$out")" >&2
      return 1
    fi
  }
  export -f copy_one
  export BUCKET

  echo "Copying $(wc -l <"$WORK/manifest.tsv" | tr -d ' ') objects, $PARALLEL_COPIES at a time ..."
  # xargs runs every copy even when one fails; the check below counts the gaps.
  # shellcheck disable=SC2016 # $1 is expanded by the child bash
  tr '\n' '\0' <"$WORK/manifest.tsv" \
    | xargs -0 -n 1 -P "$PARALLEL_COPIES" bash -c 'copy_one "$1"' _ \
    || true
fi

# --- 4. Check that every chosen key is under the target -----------------------

aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$TARGET_PREFIX" \
  --query 'Contents[].Key' --output json >"$WORK/copied.json"
[ -s "$WORK/copied.json" ] || echo 'null' >"$WORK/copied.json"

jq -r --slurpfile copied "$WORK/copied.json" '
  (($copied[0] // []) | map({key: ., value: true}) | from_entries) as $present
  | .copy[] | select($present[.target] | not) | .target
' "$WORK/plan.json" >"$WORK/missing.txt"

if [ -s "$WORK/missing.txt" ]; then
  echo
  echo "ERROR: $(wc -l <"$WORK/missing.txt" | tr -d ' ') keys are not under the target; they are listed in" >&2
  echo "$WORK/missing.txt. Run the script again with the same cutoff to copy them." >&2
  exit 1
fi

echo
echo "All $to_copy keys are under s3://$BUCKET/$TARGET_PREFIX"
echo
echo "  WAL-G:    WALG_S3_PREFIX=s3://$BUCKET/${TARGET_PREFIX}postgres"
echo "  OpenBao:  s3://$BUCKET/${TARGET_PREFIX}openbao/"
echo
echo "The versions copied, with their ETags, are in $WORK/plan.json."
