terraform {
  required_version = ">= 1.12"

  backend "s3" {
    bucket       = "forge-central-tfstate-811430801166"
    key          = "prod/apps.tfstate"
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
