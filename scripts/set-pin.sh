#!/usr/bin/env bash
# Pin one service of one stage at one image digest.
#
# This is the only place that knows how a pin is written. The bump workflow, the
# refresh workflow, the promotion workflow and a person at a terminal all go
# through here, so a change to the file's shape lands in one place.
#
# Usage:
#   scripts/set-pin.sh [--stage <dev|staging|prod>] <service> <sha256:...>
#
# The stage defaults to dev. Example:
#   scripts/set-pin.sh sprue "$(crane digest ghcr.io/fil-forge/sprue:main)"
#
# Prints `changed=true` on stdout when the file was rewritten and
# `changed=false` when the service was already pinned there, and exits 0 either
# way. Everything a person reads goes to stderr, so a caller can append stdout
# straight to $GITHUB_OUTPUT. Anything else is an error: an unknown stage or
# service, a malformed digest, a pin the pattern did not fit, or an edit that
# touched more than the one line.
#
# Prerequisites:
#   - a git work tree, because the one-line assertion reads `git diff`
#   - no AWS credentials, and nothing outside the tfvars is written
set -euo pipefail

usage() {
  echo "usage: scripts/set-pin.sh [--stage <dev|staging|prod>] <service> <sha256:...>" >&2
  exit 2
}

STAGE=dev
case "${1-}" in
  -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --stage)   STAGE="${2-}"; shift 2 2>/dev/null || usage ;;
esac
case "${1-}" in
  "") usage ;;
  -*) echo "unknown option: $1" >&2; exit 2 ;;
esac

SERVICE="$1"
DIGEST="${2-}"
shift 2 2>/dev/null || usage
[ $# -eq 0 ] || { echo "ERROR: unexpected argument: $1" >&2; exit 2; }

case "$STAGE" in
  dev|staging|prod) ;;
  *) echo "ERROR: unknown stage '$STAGE'" >&2; exit 1 ;;
esac

# The keys terraform/modules/apps/variables.tf declares. An unknown one would
# otherwise leave the file untouched and pass for "already pinned".
case "$SERVICE" in
  sprue|hilt|swarf|delegator|signing_service|plc) ;;
  *) echo "ERROR: unknown service '$SERVICE'" >&2; exit 1 ;;
esac

[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "ERROR: malformed digest '$DIGEST', expected sha256:<64 hex>" >&2
  exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="terraform/envs/$STAGE/apps/terraform.tfvars"
cd "$ROOT"

sed -i.bak -E \
  "s|^([[:blank:]]*${SERVICE}[[:blank:]]*=[[:blank:]]*\")sha256:[0-9a-f]{64}(\")$|\1${DIGEST}\2|" \
  "$FILE"
rm -f "$FILE.bak"

# Read the result rather than trusting sed. A pattern that matched nothing
# leaves the file untouched too, so a key written differently than expected
# would otherwise pass for "already pinned".
if ! grep -qE "^[[:blank:]]*${SERVICE}[[:blank:]]*=[[:blank:]]*\"${DIGEST}\"$" "$FILE"; then
  echo "ERROR: $FILE does not pin $SERVICE at $DIGEST" >&2
  git --no-pager diff -- "$FILE" >&2
  grep -nE "^[[:blank:]]*${SERVICE}[[:blank:]]*=" "$FILE" >&2 || true
  exit 1
fi

changes="$(git diff --numstat -- "$FILE")"
if [ -z "$changes" ]; then
  echo "$SERVICE is already pinned at $DIGEST in $STAGE" >&2
  echo "changed=false"
  exit 0
fi
if [ "$changes" != "$(printf '1\t1\t%s' "$FILE")" ]; then
  echo "ERROR: expected a one-line change" >&2
  git --no-pager diff -- "$FILE" >&2
  exit 1
fi

echo "pinned $SERVICE at $DIGEST in $STAGE" >&2
echo "changed=true"
