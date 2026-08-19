terraform {
  required_version = ">= 1.12"

  # This root's own state, in the bucket this root creates. See the non-prod copy
  # of this directory, and the bootstrap procedure in the README: the first apply
  # in a new account runs against a local backend and then moves its state here.
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
