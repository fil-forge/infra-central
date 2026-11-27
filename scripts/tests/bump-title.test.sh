#!/usr/bin/env bash
# Tests for scripts/bump-title.sh, run from any machine:
#
#   scripts/tests/bump-title.test.sh
#
# Each case pipes a commit message into the script and compares the one line
# it prints. Plain bash and jq, written for the bash 3.2 macOS ships as well as
# for a current one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../bump-title.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bump-title-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

STAGE="in staging"
REPO=fil-forge/hilt
DIGEST=sha256:6c17e7e0000000000000000000000000000000000000000000000000000000ff
FALLBACK="Bump hilt in staging to sha256:6c17e7e"

failures=0

pass() { printf '  ok   %s\n' "$1"; }
flunk() {
  printf '  FAIL %s\n' "$1"
  printf '       expected: %s\n' "$2"
  printf '       actual:   %s\n' "$3"
  failures=$((failures + 1))
}

# expect <description> <expected title> <message> [<source repo>]
expect() {
  local description=$1 expected=$2 message=$3 repo=${4-$REPO} actual
  actual=$(cd "$WORK" && printf '%s' "$message" | "$SCRIPT" hilt "$STAGE" "$DIGEST" "$repo")
  if [ "$actual" = "$expected" ]; then
    pass "$description"
  else
    flunk "$description" "$expected" "$actual"
  fi
}

# A subject of exactly <words> words: "Refactor" and then "lorem" repeated.
words() {
  printf 'Refactor'
  printf ' lorem%.0s' $(seq 2 "$1")
}

echo "bump-title.sh"

expect "a squash subject's trailing pull request is qualified" \
  "Bump hilt in staging: Fix tenant lock race (fil-forge/hilt#212)" \
  "Fix tenant lock race (#212)"

expect "references mid-text are qualified, closing keyword or not" \
  "Bump hilt in staging: Fixes fil-forge/hilt#12, see fil-forge/hilt#13 and fil-forge/hilt#14" \
  "Fixes #12, see GH-13 and #14"

expect "a reference to another repository is left alone" \
  "Bump hilt in staging: Revert fil-forge/sprue#40" \
  "Revert fil-forge/sprue#40"

expect "a hash that is no reference is left alone" \
  "Bump hilt in staging: Use url#fragment and #main" \
  "Use url#fragment and #main"

expect "only the first line is used" \
  "Bump hilt in staging: Add tenant quotas (fil-forge/hilt#7)" \
  "Add tenant quotas (#7)

Closes #3 on the way."

expect "backticks become quotes, other shell syntax stays literal" \
  "Bump hilt in staging: Quote \"a\" and 'b' with 'c' and \$(touch pwned) \$HOME" \
  "Quote \"a\" and 'b' with \`c\` and \$(touch pwned) \$HOME
second line"

expect "control characters become single spaces" \
  "Bump hilt in staging: Fix the tab and the carriage return" \
  "$(printf 'Fix\tthe tab\033and the carriage return\r')"

expect "a long subject is cut at a word boundary" \
  "Bump hilt in staging: $(words 15)…" \
  "$(words 30)"

expect "a cut never shortens a reference" \
  "Bump hilt in staging: $(words 12) abcde…" \
  "$(words 12) abcde #212"

expect "a subject of exactly the maximum length is kept whole" \
  "Bump hilt in staging: $(words 15)abcdef" \
  "$(words 15)abcdef"

expect "an empty message falls back to the digest" \
  "$FALLBACK" ""

expect "a blank first line falls back to the digest" \
  "$FALLBACK" "$(printf '  \t \nBody text')"

expect "no source repository falls back to the digest" \
  "$FALLBACK" "Fix tenant lock race (#212)" ""

if [ -e "$WORK/pwned" ]; then
  flunk "the subject is never run" "no file $WORK/pwned" "it exists"
else
  pass "the subject is never run"
fi

if "$SCRIPT" hilt "$STAGE" sha256:6c17e7e "$REPO" </dev/null >/dev/null 2>&1; then
  flunk "a malformed digest is refused" "a non-zero exit" "exit 0"
else
  pass "a malformed digest is refused"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
