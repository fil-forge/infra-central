# A bot keeps one promotion pull request per stage, and a person merges it

Service images move through the stages one hop at a time. Staging takes dev's pins, and prod takes
staging's. For each hop, the `fil-forge-bot` GitHub App keeps one pull request that sets every pin
in the target's `apps/terraform.tfvars` to what the source stage pins, and lists the commits each
service brings over what the target runs. The bot never merges it. Merging is the promotion, and
every merge to `main` applies all three stages with no further confirmation
([FIL-1158](https://linear.app/filecoin-foundation/issue/FIL-1158)).

| Target  | Source  | Branch                | Rebuilt after   |
|---------|---------|-----------------------|-----------------|
| staging | dev     | `bot/promote-staging` | `smoke-dev`     |
| prod    | staging | `bot/promote-prod`    | `smoke-staging` |

[`scripts/promote.sh`](../../scripts/promote.sh) does the work, and
[`promote.yml`](../../.github/workflows/promote.yml) runs it. infra-nodes promotes its nodes the same
way, with one target.

## Prod promotes from staging

An image reaches prod only after staging has run it, so the order is enforced by the workflow
rather than by whoever merges. A fix needs two merges to reach prod: the staging promotion first,
then the prod promotion once staging passes its smoke test on that merge.

## Each pull request waits for its source stage's smoke test

On every push to `main`, Check and deploy applies all three stages in parallel and then smoke-tests
each one. Its `promote-staging` job runs after `smoke-dev` passes, and `promote-prod` after
`smoke-staging` passes. `smoke-staging` runs on every push, not only after a staging promotion,
because every push applies staging. A failure in one chain does not hold the other: a broken dev
leaves the prod pull request current.

When a source stage fails its smoke test, its target's pull request stops refreshing. The `main`
ruleset only merges a branch that is up to date, so that pull request cannot merge until a later
push passes the smoke test. A broken image in dev is usually fixed by the next dev bump, which is
also the push that brings the staging pull request up to date.

## Branches are built on the commit that was deployed

Each run builds its branch on the commit it deployed and smoke-tested (`github.sha`), not on the
tip of `main`. `main` may have moved on during the run, to pins the source stage has not been
tested with yet. If it has, the branch is briefly behind `main`, and the next run, which Check and
deploy has already queued, brings it up to date. The pull request body names the commit and links
the run in which the source stage passed.

Every source commit in the change list comes from dev's history, including for prod. Every digest
entered through a dev bump, and that bump's message names the commit the image was built from. A
digest dispatched by hand, or seeded with its stage, has no such commit, and the pull request says
so in place of a change list.

## A person holds a service back by pushing to the branch

The bot leaves a branch alone while its pull request is open and the head commit's author or
committer is someone other than the bot. It neither rebuilds nor deletes such a branch, even after
the source and target pins come to match. The committer counts as well, because amending a bot
commit keeps the bot as author. Clicking "Update branch" on the pull request sets a committer other
than the bot, so it holds the branch too. After that pull request is merged or closed, the bot rebuilds the
branch from scratch on its next run.

## The bot never enables auto-merge

A new head is a new set of images, and deciding to deploy them is a person's call. If someone
enables auto-merge and the bot later pushes a new head, the bot disables it.

## A manual run skips the smoke test

Running `promote.yml` by hand with a target rebuilds that target's pull request on the current tip
of `main`, without waiting for a smoke test. The pull request then says it was built by a manual
run. This is for times when a source stage keeps failing its smoke test for reasons unrelated to
the images being promoted.

## Only service images are promoted

The provision Lambda's `provision_image_digest` stays a manual edit for every stage. Prod has its
own ECR repository, so a digest copied from staging can name an image that was never pushed there,
and the workflow has no AWS credentials to check before proposing it.
