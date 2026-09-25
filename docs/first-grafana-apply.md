# Standing up the Grafana root

One sitting, after #133 has merged, from `main`.

There is no separate plan step. `tofu apply` runs a plan, prints it, and waits
for you to type `yes` -- so the review happens at the terminal, at the moment it
matters, by the person who can act on it. Running a plan first would show you the
same thing twice.

While you are in here with AWS credentials, there is a second small job at the
end that retires the need for anyone to do this by hand again.

It needs two credentials that rarely sit with the same person, which is why this
page exists rather than a line in a pull request:

- **AWS, for the `filone-sandbox` account** (`654654381893`), with read and write
  on `s3://forge-central-tfstate-654654381893/grafana/*`. The same access whoever
  applies the bootstrap roots already has. The CI roles deliberately cannot reach
  this key: `state_key_prefixes` in `terraform/envs/bootstrap/nonprod/account`
  names one prefix per stage, and `grafana` is not a stage.
- **A Grafana service account token** for `forge-terraform`. If you have Grafana
  org Admin, mint your own: Administration -> Users and access -> Service
  accounts -> `forge-terraform` -> Add service account token. An account can hold
  several, so this needs no coordination and nothing has to be sent to you.
  Otherwise ask for one through 1Password, not a chat window.

You need both for either sitting: a plan reads every managed resource, and
refreshing `grafana_folder_permission` calls `folders.permissions:read`, which is
an Admin-level action. There is no read-only credential that can plan this root.

## Before you start

Check these rather than assuming; each one has a way of not being true.

1. **The `Forge` folder exists**, uid `fhmttd`, made by hand in the UI. Nothing
   in the root creates it: making a folder at the *root* of the tree needs
   `folders:create` scoped to `folders:uid:general`, which no folder-scoped grant
   confers. Everything under it is created by this root.
2. **`forge-terraform` (numeric id 83) holds `Admin` on that folder.** Folder
   permission level, not the org role -- its basic role is `No basic role` and
   should stay that way. This single grant is what lets the apply create the
   three subfolders and write their permissions.
3. **#133 has merged**, and you are on `main`. #135 and #139 may still be open;
   they only add alert rules and they go out through CI afterwards.
4. **`aws sts get-caller-identity` returns account `654654381893`.**

## Steps

```bash
git checkout main && git pull
export TF_VAR_grafana_auth='<the forge-terraform token>'
cd terraform/envs/grafana
```

### 1. Initialise

```bash
tofu init
```

Nothing to pin: `versions.tofu` constrains `grafana/grafana` to `~> 4.0` and
`.terraform.lock.hcl` is committed at 4.46.0, both of them since #133. `init`
installs that version and should report no changes to the lock file. If it
rewrites the lock, stop and work out why before applying -- a lock file that
moves under an operator is a provider upgrade nobody reviewed.

One loose end, which is not a reason to stop: the committed lock carries
thirteen `h1:` hashes where the AWS roots carry fifteen. That is a different
provider with a different set of release platforms, not necessarily a gap, but
nobody has checked. If CI ever rewrites this file, that is the first thing to
look at, and `tofu providers lock -platform=linux_amd64 -platform=darwin_arm64
-platform=darwin_amd64` is the command that settles it.

### 2. Delete the two old dashboards

In the UI, delete `forge-central` and `forge-regions` wherever they currently
live. They are not adopted: they sit in a different folder, nothing links to
them, and their version history is not worth carrying.

**This has to happen before the apply, not after.** `overwrite` is unset on both
resources, and the provider documents it as what you set "to overwrite existing
dashboard with newer version, same dashboard title in folder or same dashboard
uid". The uids are pinned in the committed JSON, so creating `forge-central`
while a `forge-central` still exists **fails**. It does not quietly make a
duplicate; it stops the apply.

### 3. Apply

```bash
tofu apply
```

This prints the plan and waits for `yes`. Read it before you answer. Expect:

- **Three folders created**: `forge`, `forge-alerts`, `forge-previews`, each with
  `parent_folder_uid = "fhmttd"`.
- **Four folder permission sets written**, one of them on `fhmttd` itself.
- **Two dashboards created.**
- **Six alert rules created**, across three rule groups, if you are applying a
  `main` that already has #135 and #139. Nine resources without them.

`Plan: N to add, 0 to change, 0 to destroy.` Anything proposing to **destroy** or
**replace** is wrong -- the state is empty, so everything should be a create.
Answer `no` and say what it showed.

### 4. Let CI take over from here

You are the only person who can do this part, and it means nobody has to do any
of the above again.

In `terraform/envs/bootstrap/nonprod/account/main.tf`, `state_key_prefixes` is
one prefix per stage:

```hcl
state_key_prefixes = module.constants.nonprod_stages   # ["dev", "staging"]
```

`grafana` is not a stage, so neither CI role can reach `grafana/forge.tfstate`.
Add it, and apply that root. After this, the `apply-grafana` job can do what you
just did, and #135 and #139 deploy by merging.

Do this **before** anyone sets `GRAFANA_APPLY_ENABLED`: without it every push to
main fails at `tofu init` with an access denial, on every merge, until someone
notices.

## Afterwards

Three checks, in the Grafana UI:

1. **The three folders are under `Forge`, not beside it.** If they landed at the
   root, the permission inheritance the whole arrangement rests on is not
   happening, and `Alerts (managed in git)` is not actually read-only.
2. **Save a trivial edit to a dashboard in `Dashboards`.** This is the one
   assumption nothing could test beforehand: that Grafana resolves a child's
   `Edit` over the parent's inherited `View` as `Edit`. If the save is refused,
   say so -- the folder is read-only, which is the safe direction to be wrong in
   but still wrong.
3. **Confirm `Alerts (managed in git)` offers no Save.** That one is the cordon.

Then say in the thread what the apply did and what the three checks showed, and
whether you got to step 4.

## If it goes wrong

- **`AccessDenied` at `tofu init`.** The AWS credential cannot reach
  `grafana/forge.tfstate`. Nothing to do with Grafana; see the prerequisite
  above.
- **A 403 or 401 from Grafana.** Either the token is not `forge-terraform`'s, or
  that account does not hold `Admin` on `fhmttd`. Note that `Admin` here is the
  folder permission, and a service account with `No basic role` shows nothing at
  the org level -- that is correct, not a misconfiguration.
- **An alert rule is rejected.** The likeliest failure, and the one nothing
  could have caught earlier. Paste the error; do not try to fix the rule by hand
  in the UI, because the folder is git-managed and the next apply would revert
  it.
- **Anything else.** Answer `no` at the confirmation prompt, paste the output.
  Nothing here is urgent enough to push through a surprise.

## What only the apply can tell you

Three of the six alert rules came from rules built by hand in the UI and
exported, so their shapes are known good. The other three were written from the
same pattern and have never met the Grafana API.

A plan cannot check them. Each rule's query is a `model = jsonencode(...)`, which
is an opaque *string* to OpenTofu: plan and `validate` check the block structure
around it, and Grafana checks what is inside it only on write. So the apply is
the first real test of those three, and a rejected rule at that point is expected
rather than alarming.
