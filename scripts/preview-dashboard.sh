#!/usr/bin/env bash
# Rewrite a committed dashboard into a disposable preview of itself.
#
# A pull request that changes a dashboard is reviewed as a JSON diff, which says
# very little about whether the panel reads correctly. Deploying the changed
# dashboard under its own uid, into a folder nobody reads for real, gives a
# reviewer the thing itself against live data.
#
#   scripts/preview-dashboard.sh <dashboard.json> <uid-suffix> <label>
#   scripts/preview-dashboard.sh forge-central.json pr-133 "PR #133"
#
# Prints the preview document on stdout. It changes four things and nothing else:
#
#   metadata.name   forge-central          -> forge-central-pr-133
#   spec.title      Forge Central          -> Forge Central (PR #133)
#   spec.editable   true                   -> false
#   spec.tags       []                     -> ["preview"]
#
# and rewrites every /d/<uid> in the document to the preview's uid. That last one
# is the part worth keeping: each dashboard hardcodes its own uid in the
# drill-down data link on its overview table, so a preview whose metadata alone
# was rewritten would throw the reviewer into the production dashboard on the
# first click. The replacement is literal rather than a regex, so a uid carrying
# a regex metacharacter cannot misfire.
#
# The transformation is one-directional and the output is disposable. Nothing
# syncs back out of a preview, so there is no inverse to get wrong.
set -euo pipefail

if [ $# -ne 3 ]; then
  cat >&2 <<'USAGE'
usage: preview-dashboard.sh <dashboard.json> <uid-suffix> <label>
   eg: preview-dashboard.sh forge-central.json pr-133 "PR #133"
USAGE
  exit 2
fi

file=$1
suffix=$2
label=$3

uid=$(jq -r '.metadata.name' "$file")
if [ -z "$uid" ] || [ "$uid" = "null" ]; then
  printf 'no metadata.name in %s\n' "$file" >&2
  exit 1
fi

preview_uid="${uid}-${suffix}"

# Grafana caps a uid at 40 characters. Truncating would collide across pull
# requests, so fail instead and let the caller shorten the suffix.
if [ "${#preview_uid}" -gt 40 ]; then
  printf 'preview uid %s is %d characters, over the 40 Grafana allows\n' \
    "$preview_uid" "${#preview_uid}" >&2
  exit 1
fi

jq \
  --arg uid "$uid" \
  --arg preview_uid "$preview_uid" \
  --arg label "$label" '
  # Literal, not regex: sub() would treat a metacharacter in the uid as syntax.
  def replace_all($from; $to): split($from) | join($to);

  ( walk(if type == "string" then replace_all("/d/" + $uid; "/d/" + $preview_uid) else . end) )
  | .metadata.name = $preview_uid
  | .spec.title = "\(.spec.title) (\($label))"
  | .spec.editable = false
  | .spec.tags = ((.spec.tags // []) + ["preview"] | unique)
' "$file"
