#!/usr/bin/env bash
# Mint the credentials a regional appliance needs from central, and print each
# one once for delivery to whoever operates that node:
#
#   - the unseal token its OpenBao authenticates with to central's transit key
#   - the access key it writes its backups with, in stages that take backups
#
# The minting happens inside the provision Lambda, in AWS. What comes back is
# not either credential: it is a single-use wrapping token with a short TTL per
# credential, which the node exchanges against central OpenBao. So the
# credentials never transit the channel that carries the hand-off, and an
# interception makes the node's own exchange fail rather than passing
# unnoticed. See docs/appliance-onboarding.md for the delivery rules, which
# matter.
#
# Safe to re-run. A credential the region already holds is skipped, so running
# this for an appliance that is already set up mints only what it lacks, and a
# second run mints nothing. Dev takes no backups, so there the backup key is
# reported as not applicable.
#
# After a run that failed while minting, re-run with the reissue flag the
# failure names. The failed call may have created a credential before its
# response was lost, and a plain re-run would skip a credential nobody received.
# Each reissue flag mints as usual when the region holds nothing.
#
# Two rounds of invocations, always in this order:
#   1. without confirmation, which reads OpenBao and IAM and prints the plan
#   2. after you approve it, with confirmation, which mints
#
# The region's transit key and backup writer user must already exist. Both are
# created by the apply from appliance_regions in the stage's terraform.tfvars,
# so a region that has not been committed and merged fails here rather than
# being created on the spot.
#
# Usage:
#   scripts/mint-appliance-credentials.sh --region us-east-9 --node-ip 203.0.113.7
#
# Options:
#   --region                appliance region label                  (required)
#   --node-ip               the node's Elastic IP, bound as a /32   (required)
#   --node-cidr             bind to this CIDR instead of --node-ip
#   --stage                 stage holding the transit key            (default: dev)
#   --period                renewal tolerance                        (default: 72h)
#   --wrap-ttl              how long the hand-off may sit unclaimed  (default: 24h)
#   --reissue-unseal-token  replace the region's live unseal token
#   --reissue-backup-key    delete the region's backup key and mint another
#   --yes                   skip the interactive prompt
#
# Prerequisites:
#   - AWS credentials for the account holding the stage
#   - the node's Elastic IP already allocated, which is its own apply
set -euo pipefail

STAGE="${STAGE:-dev}"
REGION=""
NODE_IP=""
NODE_CIDR=""
PERIOD=""
WRAP_TTL=""
REISSUE_UNSEAL_TOKEN=false
REISSUE_BACKUP_KEY=false
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --region)               REGION="$2"; shift 2 ;;
    --node-ip)              NODE_IP="$2"; shift 2 ;;
    --node-cidr)            NODE_CIDR="$2"; shift 2 ;;
    --stage)                STAGE="$2"; shift 2 ;;
    --period)               PERIOD="$2"; shift 2 ;;
    --wrap-ttl)             WRAP_TTL="$2"; shift 2 ;;
    --reissue-unseal-token) REISSUE_UNSEAL_TOKEN=true; shift ;;
    --reissue-backup-key)   REISSUE_BACKUP_KEY=true; shift ;;
    --yes|-y)               ASSUME_YES=true; shift ;;
    # Named for what it reissues now that the script mints more than one
    # credential. Refused rather than mapped, so an old runbook command stops
    # and says which credential it means.
    --reissue)
      echo "--reissue is now --reissue-unseal-token; use --reissue-backup-key for the backup key" >&2
      exit 2 ;;
    -h|--help)
      # The comment block at the top of this file, up to the first code line.
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REGION" ] || { echo "ERROR: --region is required" >&2; exit 2; }

if [ -z "$NODE_CIDR" ]; then
  [ -n "$NODE_IP" ] || { echo "ERROR: --node-ip or --node-cidr is required" >&2; exit 2; }
  NODE_CIDR="${NODE_IP}/32"
fi

command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found in PATH" >&2; exit 1; }

FUNCTION="fc-${STAGE}-provision"

# The one file the Lambda's response is written to, created with a private umask
# and removed however this script ends. On a confirming call it holds a
# wrapping token, and this is the only place on an operator's disk one ever
# exists. The signals are trapped so an interrupted script still cleans up:
# bash runs no EXIT trap when an untrapped signal kills it, and the file would
# be left holding a live wrapping token for the rest of its 24 hours. The
# signal handler exits, which runs the EXIT trap; a handler that only removed
# the file would let the script carry on minting.
RESPONSE="$(umask 077; mktemp)"
trap 'rm -f "$RESPONSE"' EXIT
trap 'exit 130' INT TERM HUP

# invoke <phase> <confirm> — call a phase and print its JSON response. A Lambda
# error is reported as a successful invocation with FunctionError set, so that
# is checked separately.
#
# Every failure has to become an explicit return: bash drops errexit inside
# command substitution, and the callers read this function through one.
invoke() {
  local phase="$1" confirm="$2" reissue payload response
  case "$phase" in
    appliance-token)      reissue="$REISSUE_UNSEAL_TOKEN" ;;
    appliance-backup-key) reissue="$REISSUE_BACKUP_KEY" ;;
    *) echo "ERROR: invoke: unknown phase $phase" >&2; return 1 ;;
  esac

  payload="$(jq -nc \
    --arg phase "$phase" \
    --argjson confirm "$confirm" \
    --arg region "$REGION" \
    --arg cidr "$NODE_CIDR" \
    --arg period "$PERIOD" \
    --arg wrap "$WRAP_TTL" \
    --argjson reissue "$reissue" \
    '{phase:$phase, confirm:$confirm, region:$region, reissue:$reissue}
     + (if $phase  == "appliance-token" then {node_cidr:$cidr} else {} end)
     + (if $period == "" or $phase != "appliance-token" then {} else {period:$period} end)
     + (if $wrap   == "" then {} else {wrap_ttl:$wrap} end)')"

  if ! response="$(aws lambda invoke \
    --function-name "$FUNCTION" \
    --cli-binary-format raw-in-base64-out \
    --payload "$payload" \
    --cli-read-timeout 900 \
    "$RESPONSE")"; then
    echo "ERROR: aws lambda invoke failed for the $phase phase" >&2
    return 1
  fi

  if [ "$(jq -r '.FunctionError // empty' <<<"$response")" != "" ]; then
    echo "ERROR: the $phase phase failed:" >&2
    jq -r '.errorMessage // .' "$RESPONSE" >&2
    return 1
  fi

  cat "$RESPONSE"
  : >"$RESPONSE"
}

echo "=== Mint the ${REGION} appliance credentials ==="
echo "  Lambda:   $FUNCTION"
echo "  Region:   $REGION"
echo "  Bound to: $NODE_CIDR"
echo

echo "Reading OpenBao and IAM (nothing is minted yet)…"
token_plan="$(invoke appliance-token false)"
backup_plan="$(invoke appliance-backup-key false)"

echo "Unseal token:"
jq -r '
  "  Transit key:  appliance-unseal-\(.token_plan.region)",
  "  Key versions: latest \(.token_plan.key_latest_version), decrypts from \(.token_plan.key_min_decryption_version)",
  (if .token_plan.key_min_decryption_version > 1 then
    "  WARNING:      the key no longer decrypts versions below \(.token_plan.key_min_decryption_version), so appliance OpenBao snapshots wrapped by those versions do not restore"
  else empty end),
  "  Period:       \(.token_plan.period)",
  "  Wrap TTL:     \(.token_plan.wrap_ttl)",
  "  Action:       \(.token_plan.action)",
  (if .token_plan.accessor == null then empty else
    "  On record:    accessor \(.token_plan.accessor), live: \(.token_plan.token_live)"
  end)
' <<<"$token_plan"
echo
echo "Backup key:"
jq -r '
  "  Action:       \(.backup_key_plan.action)",
  (if .backup_key_plan.action == "not-applicable" then
    "  This stage takes no appliance backups."
  else
    "  User:         \(.backup_key_plan.user)",
    "  Bucket:       \(.backup_key_plan.bucket)",
    "  Key prefix:   \(.backup_key_plan.key_prefix)",
    (if (.backup_key_plan.existing_key_ids // []) == [] then empty else
      "  On record:    access key \(.backup_key_plan.existing_key_ids | join(", "))"
    end)
  end)
' <<<"$backup_plan"
echo

token_action="$(jq -r '.token_plan.action' <<<"$token_plan")"
backup_action="$(jq -r '.backup_key_plan.action' <<<"$backup_plan")"

mints() { [ "$1" = mint ] || [ "$1" = reissue ]; }

if ! mints "$token_action" && ! mints "$backup_action"; then
  echo "Nothing to mint: the region holds every credential it needs."
  echo
  echo "If a credential leaked or never reached the node, re-run with"
  echo "--reissue-unseal-token for the unseal token or --reissue-backup-key for the backup key."
  exit 0
fi

if [ "$ASSUME_YES" != true ]; then
  if [ "$token_action" = reissue ]; then
    echo "The region's current unseal token will be REVOKED once its replacement is"
    echo "minted. A node still using it stops being able to unseal at its next restart."
  fi
  if [ "$backup_action" = reissue ]; then
    echo "The region's backup key will be DELETED before its replacement is minted."
    echo "The node's uploads fail until it stores the new key."
  fi
  read -r -p "Type 'mint' to proceed: " reply
  [ "$reply" = "mint" ] || { echo "Aborted; nothing was minted."; exit 1; }
  echo
fi

# Each credential is minted and then printed straight away, so a failure in the
# second phase cannot swallow a wrapping token the first one already issued.
failed=false

if mints "$token_action"; then
  if token_result="$(invoke appliance-token true)"; then
    jq -r '
      "Minted the unseal token. Accessor \(.token_result.accessor) is recorded in SSM;",
      "the token itself is stored nowhere and cannot be printed again.",
      "",
      "Give the node operator this unseal-token wrapping token:",
      "",
      "    \(.token_result.wrapping_token)",
      "",
      "It can be exchanged once, within \(.token_result.wrap_ttl), and only for this",
      "node'"'"'s credential. On the node, scripts/host/provision-platform.sh asks for it,",
      "exchanges it at central and stores what comes back 0400 root.",
      ""
    ' <<<"$token_result"
    unset token_result
  else
    failed=true
    echo "The unseal token was not delivered; see the error above. The phase may" >&2
    echo "have minted it before failing, so re-run with --reissue-unseal-token: it" >&2
    echo "revokes a token nobody received, and mints as usual if there is none." >&2
    echo >&2
  fi
else
  echo "Unseal token skipped: the region already holds a live one."
  echo
fi

if mints "$backup_action"; then
  if backup_result="$(invoke appliance-backup-key true)"; then
    jq -r '
      "Minted the backup key. Only its ID is kept; the secret exists only inside",
      "the wrapping token below and cannot be printed again.",
      "",
      "Give the node operator this backup-key wrapping token:",
      "",
      "    \(.backup_key_result.wrapping_token)",
      "",
      "It can be exchanged once, within \(.backup_key_result.wrap_ttl). On the node,",
      "scripts/host/provision-backups.sh asks for it and stores the key in the",
      "node'"'"'s own OpenBao.",
      "",
      "For your record (not secret):",
      "  Bucket:         \(.backup_key_result.bucket)",
      "  Key prefix:     \(.backup_key_result.key_prefix)",
      "  AWS region:     \(.backup_key_result.aws_region)",
      "  Access key ID:  \(.backup_key_result.access_key_id)",
      (if (.backup_key_result.deleted_key_ids // []) == [] then empty else
        "  Deleted keys:   \(.backup_key_result.deleted_key_ids | join(", "))"
      end),
      ""
    ' <<<"$backup_result"
    unset backup_result
  else
    failed=true
    echo "The backup key was not delivered; see the error above. The phase may have" >&2
    echo "created it before failing, so re-run with --reissue-backup-key: it deletes" >&2
    echo "a key nobody received, and mints as usual if there is none." >&2
    echo >&2
  fi
elif [ "$backup_action" = not-applicable ]; then
  echo "Backup key not applicable: this stage takes no appliance backups."
  echo
else
  echo "Backup key skipped: the region's writer already has one."
  echo
fi

cat <<'EOF'
Chat is an acceptable channel for a wrapping token; a view-once 1Password link
is better. There is nothing for the operator to unwrap or write by hand.

If an exchange on the node fails, treat it as a compromise rather than a
hiccup: someone else spent the token. Re-run this script with --reissue-unseal-token
for the unseal token or --reissue-backup-key for the backup key, and find out who
read the channel.
EOF

[ "$failed" = false ] || exit 1
