#!/usr/bin/env bash
# Put a Grafana dashboard export into the form this repository commits.
#
# A UI export carries fields that describe the server rather than the dashboard:
# resourceVersion, generation, creationTimestamp and updatedBy under metadata,
# the cached option list behind every template variable, and whichever variable
# values the person who last hit save happened to have selected. Left in, every
# re-export rewrites lines that mean nothing and a real change is lost among
# them. This strips the first two and takes the variable selections from the file
# already in git, so a stray selection never reaches a diff.
#
#   scripts/normalise-dashboard.sh export.json                    normalise in place, on stdout
#   scripts/normalise-dashboard.sh export.json committed.json     keep committed.json's selections
#   scripts/normalise-dashboard.sh --check file.json...           fail if a file is not normalised
#
# `make check` runs the --check form over the committed dashboards, so a raw
# export cannot land by accident. It needs no Grafana credentials and no network.
#
# Two known sources of churn are deliberately left alone. Each panel carries a
# vizConfig.version that is the Grafana build it was last edited under, so a
# Cloud upgrade plus one save rewrites all of them; dropping it here would be a
# guess about whether Grafana still accepts the document without it. And a
# variable added in the UI arrives with no counterpart in the committed file, so
# its selection passes through as exported.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: normalise-dashboard.sh <export.json> [committed.json]
       normalise-dashboard.sh --check <file.json>...
USAGE
  exit 2
}

# $1 the document to normalise, $2 the document to take variable selections from.
normalise() {
  jq --slurpfile keep "$2" '
    (($keep[0].spec.variables // [])
      | map({key: .spec.name, value: .spec.current})
      | from_entries) as $selected
    | .metadata |= {name: .name}
    | .spec.variables |= map(
        .spec.options = []
        | if ($selected[.spec.name] // null) != null
          then .spec.current = $selected[.spec.name]
          else .
          end
      )
  ' "$1"
}

[ $# -ge 1 ] || usage

if [ "$1" = "--check" ]; then
  shift
  [ $# -ge 1 ] || usage
  status=0
  for file in "$@"; do
    normalised=$(normalise "$file" "$file")
    if [ "$normalised" != "$(<"$file")" ]; then
      printf 'not normalised: %s\n' "$file" >&2
      diff -u "$file" - <<<"$normalised" >&2 || true
      status=1
    fi
  done
  if [ "$status" -ne 0 ]; then
    printf '\nrun: scripts/normalise-dashboard.sh <file> > <file>.new && mv <file>.new <file>\n' >&2
  fi
  exit "$status"
fi

case $# in
1) normalise "$1" "$1" ;;
2) normalise "$1" "$2" ;;
*) usage ;;
esac
