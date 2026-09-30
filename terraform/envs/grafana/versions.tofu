terraform {
  required_version = ">= 1.12"

  # No stage in the key. The dashboards describe every stage at once through a
  # $stage template variable, so this root belongs to none of them. The state
  # sits in the nonprod bucket because that is where an operator already applies
  # the bootstrap roots, and because nothing in this root is account-specific.
  #
  # Under a grafana/ prefix, like every other key in this bucket. "grafana" is in
  # github-actions-iam's state_key_prefixes alongside one entry per stage the
  # workflow deploys, so both CI roles reach this state: the apply role writes
  # it, the plan role reads it. The grant lands when someone applies
  # terraform/envs/bootstrap/nonprod/account by hand, not when that code merges
  # -- the roles are created by that root, so nothing changes until it runs.
  #
  # Bootstrap state is still held out of the list, on the grounds the variable's
  # description gives: those roots are applied by an operator from a laptop, so
  # no CI role needs them.
  backend "s3" {
    bucket       = "forge-central-tfstate-654654381893"
    key          = "grafana/forge.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }

  # Pinned, with .terraform.lock.hcl committed beside it, the way every other
  # root here is. The lock file is what actually fixes the version; this
  # constraint bounds what a regeneration or a `tofu init -upgrade` may pick.
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.0"
    }
  }
}
