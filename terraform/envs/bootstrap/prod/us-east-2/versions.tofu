terraform {
  required_version = ">= 1.12"

  # An ordinary backend block: ../account/ creates this bucket, so this root has
  # no bootstrap dance of its own and `tofu init` is all it takes.
  #
  # `region` here is the *bucket's* region, not this root's. See the non-prod copy
  # of this file for what a copy of this directory for another region changes.
  backend "s3" {
    bucket       = "forge-central-tfstate-811430801166"
    key          = "bootstrap/us-east-2.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
