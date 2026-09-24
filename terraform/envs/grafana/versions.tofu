terraform {
  required_version = ">= 1.12"

  # No stage in the key. The dashboards describe every stage at once through a
  # $stage template variable, so this root belongs to none of them. The state
  # sits in the nonprod bucket because that is where an operator already applies
  # the bootstrap roots, and because nothing in this root is account-specific.
  #
  # Under a grafana/ prefix, like every other key in this bucket, and outside
  # every prefix in github-actions-iam's state_key_prefixes, which is one per
  # stage the workflow deploys. So neither CI role can read or write this state,
  # the same way bootstrap state is held out. If CI ever applies this root,
  # adding "grafana" to that list is the whole IAM change.
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
