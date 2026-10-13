#!/usr/bin/env bash
# Open, refresh or close the pull request that promotes one stage's images to
# the next.
#
# Dev's pins move on their own: every image a service publishes gets a bump pull
# request that the bot merges. Staging's and prod's move only when a person
# merges a promotion, and promotion goes one hop at a time:
#   staging  takes dev's pins,      on bot/promote-staging
#   prod     takes staging's pins,  on bot/promote-prod
# Each target keeps one pull request that sets every one of its pins to what the
# source stage pins at BASE, and lists what each service brings over what the
# target runs. It never enables auto-merge: merging it is the promotion.
#
# Everything it does is derived from BASE:
#   - the target already pins what the source pins: close the pull request
#   - otherwise: rebuild the branch as BASE plus the target's new pins, and open
#     or refresh the pull request
# A branch whose head the app did not both author and commit was pushed by a
# person, to hold a service back say, and is left alone while its pull request
# is open.
#
# Usage:
#   APP_SLUG=fil-forge-bot scripts/promote.sh <staging|prod> [--dry-run]
#
# --dry-run builds the commit on a scratch branch, prints it, and pushes, opens
# and closes nothing.
#
# Reads from the environment:
#   APP_SLUG       the GitHub App that opens the pull request and whose identity
#                  its commit carries
#   BASE           the commit to build on, origin/main by default; CI passes the
#                  commit whose source stage just passed its smoke test
#   SMOKE_RUN_URL  the run in which that smoke test passed; empty for a manual
#                  run, and the pull request says so
# gh reads its own credentials, GH_TOKEN included.
#
# Prerequisites:
#   - a git work tree with origin fetchable and pushable, and full history
#     (each pin's source commit is read off the dev bump that first carried it)
#   - gh authenticated, for the compare API and the pull request
#   - writes the local git identity (user.name, user.email) of the work tree
set -euo pipefail

usage() {
  echo "usage: APP_SLUG=<app> scripts/promote.sh <staging|prod> [--dry-run]" >&2
  exit 2
}

case "${1-}" in
  -h|--help) sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  staging)   SOURCE=dev ;;
  prod)      SOURCE=staging ;;
  *)         usage ;;
esac
TARGET=$1
DRY_RUN=false
case "${2-}" in
  --dry-run) DRY_RUN=true ;;
  "")        ;;
  *)         usage ;;
esac
[ $# -le 2 ] || usage

: "${APP_SLUG:?set APP_SLUG to the GitHub App that opens the promotion pull request}"
SMOKE_RUN_URL="${SMOKE_RUN_URL-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BRANCH=bot/promote-$TARGET
SOURCE_FILE=terraform/envs/$SOURCE/apps/terraform.tfvars
TARGET_FILE=terraform/envs/$TARGET/apps/terraform.tfvars
DEV_FILE=terraform/envs/dev/apps/terraform.tfvars
SUBJECT="Promote $SOURCE's images to $TARGET"

# The services a stage pins, and the repository each publishes from, mirroring
# set-pin.sh and bump-deployed-image.yml.
SERVICES=(sprue hilt swarf delegator signing_service plc)
repo_of() {
  case "$1" in
    sprue)           echo fil-forge/sprue ;;
    hilt)            echo fil-forge/hilt ;;
    swarf)           echo fil-forge/swarf ;;
    delegator)       echo fil-forge/delegator ;;
    signing_service) echo fil-forge/piri-signing-service ;;
    plc)             echo fil-forge/did-method-plc ;;
  esac
}

# The digest a file at a commit pins a service at, empty if it pins none.
pin_at() {
  git show "$1:$2" | sed -nE \
    "s|^[[:blank:]]*$3[[:blank:]]*=[[:blank:]]*\"(sha256:[0-9a-f]{64})\"[[:blank:]]*$|\1|p"
}

# The commit a digest was built from, empty if unknown. Every digest a stage runs
# reached dev first, through a bump whose message names the commit it was
# published from; the oldest commit that put the digest in dev's file is that
# bump. A digest dispatched by hand, or seeded with the stage, names no commit.
source_commit() {
  local service=$1 digest=$2 bump
  bump=$(git log --reverse --format=%H -S "$digest" "$base" -- "$DEV_FILE" | head -n 1)
  [ -n "$bump" ] || return 0
  git log -1 --format=%B "$bump" \
    | sed -nE "s|^- Commit: https://github\.com/$(repo_of "$service")/commit/([0-9a-f]{40})\$|\1|p" \
    | head -n 1
}

# What a service brings between two of its commits, one line per commit, oldest
# first. Squash-merged titles end in "(#123)", which here would link to this
# repository's pull request 123; each is qualified with the service's
# repository instead. Paged, because an unpaged compare stops at 250 commits
# without saying so, and the list would quietly leave changes out.
changes() {
  local repo=$1 from=$2 to=$3
  gh api --paginate "repos/$repo/compare/$from...$to?per_page=100" \
    --jq '.commits[] | "- " + (.commit.message | split("\n")[0]) + " (" + .sha[0:7] + ")"' \
    | sed -E "s|\(#([0-9]+)\)|($repo#\1)|g"
}

# A branch that is gone from origin must not leave a stale remote-tracking ref
# behind, or old_head would name a commit the lease below cannot match.
if ! git fetch --quiet --force origin main "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null; then
  git fetch --quiet --force origin main
  git update-ref -d "refs/remotes/origin/$BRANCH" 2>/dev/null || true
fi
old_head=$(git rev-parse --verify --quiet "origin/$BRANCH" || true)
base=$(git rev-parse --verify "${BASE:-origin/main}^{commit}")

# Only a pull request the app opened, from this repository.
pr_url=""
if [ "$DRY_RUN" = false ]; then
  pr_url=$(gh pr list --state open --head "$BRANCH" --author "app/${APP_SLUG}" \
    --json url,isCrossRepository --jq '[.[] | select(.isCrossRepository | not)][0].url // ""')
fi

# A head the app did not both author and commit was pushed by a person, who
# wanted something other than the source's pins. Rebuilding or deleting the
# branch would undo that, so it is left alone while its pull request is open;
# once that is merged or closed, the branch is fair game. The committer counts
# too, because an amended bot commit keeps the bot as its author.
if [ -n "$old_head" ] && [ -n "$pr_url" ]; then
  author=$(git log -1 --format=%an "$old_head")
  committer=$(git log -1 --format=%cn "$old_head")
  if [ "$author" != "${APP_SLUG}[bot]" ] || [ "$committer" != "${APP_SLUG}[bot]" ]; then
    echo "$BRANCH was last changed by $author (committed by $committer), not ${APP_SLUG}[bot]; leaving it for a person"
    exit 0
  fi
fi

# Which services differ, and the message describing the promotion.
body=$(mktemp)
trap 'rm -f "$body"' EXIT
moving=()
{
  echo "Sets every $TARGET pin in \`$TARGET_FILE\`"
  echo "to what \`$SOURCE_FILE\` pins at $base."
  echo "Merging this is the promotion: Check and deploy applies \`terraform/envs/$TARGET/apps\`"
  echo "on the merge commit, with no further confirmation."
  echo
  if [ -n "$SMOKE_RUN_URL" ]; then
    echo "$SOURCE passed its smoke test on that commit in $SMOKE_RUN_URL."
  else
    echo "Built by a manual run, which does not wait for $SOURCE's smoke test."
  fi
  echo
  echo "This pull request is rebuilt each time $SOURCE passes its smoke test after a push"
  echo "to \`main\`, and closed once $TARGET matches $SOURCE. To hold a service back, push"
  echo "to \`$BRANCH\` by hand: the bot leaves the branch alone while this pull"
  echo "request is open."
} >"$body"
for service in "${SERVICES[@]}"; do
  source_digest=$(pin_at "$base" "$SOURCE_FILE" "$service")
  target_digest=$(pin_at "$base" "$TARGET_FILE" "$service")
  if [ -z "$source_digest" ] || [ -z "$target_digest" ]; then
    echo "::error::${base:0:7} does not pin $service on both $SOURCE and $TARGET"
    exit 1
  fi
  [ "$source_digest" != "$target_digest" ] || continue
  moving+=("$service:$source_digest")

  repo=$(repo_of "$service")
  from=$(source_commit "$service" "$target_digest")
  to=$(source_commit "$service" "$source_digest")
  {
    echo
    echo "## $service"
    echo
    echo "\`sha256:${target_digest:7:7}\` → \`sha256:${source_digest:7:7}\`"
    echo
    if [ -n "$from" ] && [ -n "$to" ]; then
      echo "What $repo brings over $TARGET's pin, \`${from:0:7}..${to:0:7}\`:"
      echo
      # A change list the API will not give is no reason to hold the promotion.
      if ! list=$(changes "$repo" "$from" "$to"); then
        echo "The change list could not be fetched; see https://github.com/$repo/compare/$from...$to."
      elif [ -z "$list" ]; then
        echo "No commits: $SOURCE's digest was built from the same commit as $TARGET's or an older one."
      else
        echo "$list"
      fi
    else
      echo "No change list: the commit $( [ -n "$from" ] && echo "$SOURCE's" || echo "$TARGET's" ) digest was built from is unknown."
    fi
  } >>"$body"
done

if [ ${#moving[@]} -eq 0 ]; then
  echo "$TARGET already pins what $SOURCE pins at ${base:0:7}"
  if [ -n "$pr_url" ] && [ -n "$old_head" ]; then
    if git push --force-with-lease="$BRANCH:$old_head" --quiet origin ":$BRANCH"; then
      gh pr comment "$pr_url" --body "Superseded: $TARGET already pins what $SOURCE pins."
      # Usually a no-op: deleting the head closes the pull request.
      gh pr close "$pr_url" 2>/dev/null || true
      echo "closed $pr_url"
    fi
  fi
  exit 0
fi

# Attribute the commit to the app, as the bump workflow does. A commit from
# anyone else would need the extra approval the ruleset asks for on
# unattributed changes.
if [ "$DRY_RUN" = false ]; then
  bot_id=$(gh api "/users/${APP_SLUG}%5Bbot%5D" --jq .id)
  git config user.name "${APP_SLUG}[bot]"
  git config user.email "${bot_id}+${APP_SLUG}[bot]@users.noreply.github.com"
fi

# A scratch branch for a dry run, so the local bot/promote-* is never touched.
work_branch=$BRANCH
[ "$DRY_RUN" = false ] || work_branch=dry-run/promote-$TARGET
git checkout --quiet -B "$work_branch" "$base"
# Staged after each pin: set-pin.sh asserts its own edit is one line, against
# the index.
for move in "${moving[@]}"; do
  scripts/set-pin.sh --stage "$TARGET" "${move%%:*}" "${move#*:}" >/dev/null
  git add "$TARGET_FILE"
done
# Only what was staged above, whatever else the work tree holds.
git commit --quiet --file <(echo "$SUBJECT"; echo; cat "$body")

if [ "$DRY_RUN" = true ]; then
  echo "would push $BRANCH at $(git rev-parse --short HEAD), on ${base:0:7}:" >&2
  git --no-pager show --stat --format='%n%B' HEAD
  git checkout --quiet -
  git branch --quiet -D "$work_branch"
  exit 0
fi

# Already BASE plus these pins: nothing to push, and no new checks to run.
pushed=false
if [ -n "$old_head" ] \
  && [ "$(git rev-parse "$old_head^")" = "$base" ] \
  && git diff --quiet "$old_head" HEAD; then
  echo "$BRANCH is already ${base:0:7} plus $SOURCE's pins"
else
  git push --force-with-lease="$BRANCH:$old_head" --quiet origin "HEAD:refs/heads/$BRANCH"
  pushed=true
  echo "pushed $BRANCH at $(git rev-parse --short HEAD)"
fi

if [ -z "$pr_url" ]; then
  pr_url=$(gh pr create --base main --head "$BRANCH" --title "$SUBJECT" --body-file "$body")
  echo "opened $pr_url"
else
  gh pr edit "$pr_url" --title "$SUBJECT" --body-file "$body"
  echo "refreshed $pr_url"
fi

# Someone may have enabled auto-merge for an earlier head. A new head is a new
# set of images, and merging it is a person's decision, so it goes.
armed=$(gh pr view "$pr_url" --json autoMergeRequest --jq '.autoMergeRequest != null')
if [ "$armed" = true ] && [ "$pushed" = true ]; then
  gh pr merge --disable-auto "$pr_url"
  echo "disabled auto-merge, which predates this head"
fi
