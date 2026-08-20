terraform {
  required_version = ">= 1.12"

  # An ordinary backend block: ../account/ created this bucket, so this root has
  # no bootstrap dance of its own and `tofu init` is all it takes.
  #
  # `region` here is the *bucket's* region, not this root's. A copy of this
  # directory for another region changes the provider region and the key below,
  # and leaves this line as it is: the bucket is one per account, and it lives in
  # us-east-2.
  backend "s3" {
    bucket       = "forge-central-tfstate-654654381893"
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
