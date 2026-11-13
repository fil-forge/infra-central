terraform {
  required_version = ">= 1.12"

  # In the prod bucket, under a jump-host/ prefix. The CI roles reach only the
  # stage prefixes (github-actions-iam's state_key_prefixes), so no workflow can
  # read or write this state. That is intended: the root is applied by hand.
  backend "s3" {
    bucket       = "forge-central-tfstate-811430801166"
    key          = "jump-host/forge.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
