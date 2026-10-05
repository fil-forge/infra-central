# Regional bootstrap for the prod account in us-east-2: the ECR repositories the
# prod stage pulls its images from, the KMS key its Aurora cluster is encrypted
# with, and the KMS key its OpenBao seals with.
#
# The non-prod copy of this directory carries the full explanation of why the
# state bucket and the CI roles are not here but in ../account/.
#
# Nothing here has been applied yet: the prod account holds no
# forge-central/provision repository. It cannot be applied before ../account/,
# which creates the bucket this root's backend names.

provider "aws" {
  region = "us-east-2"

  allowed_account_ids = [module.constants.prod_account_id]
}

module "constants" {
  source = "../../../../modules/shared/constants"
}

module "ecr" {
  source = "../../../../modules/ecr"
}

# The prod Aurora cluster's key. It lives here rather than in the platform root
# because a cluster cannot change its key without a restore into a new cluster,
# and because a snapshot is readable only while its key is: a key created by
# the platform root would be scheduled for deletion by any destroy of that
# root, taking the final snapshot with it.
#
# Multi-region because the flag is fixed when a key is created. Backup copies
# in the DR region (FIL-1298) and the Global Database secondary (FIL-1297)
# need a replica of this key there. FIL-1445 adds that replica and the policy
# that stops anyone but a break-glass role from deleting or disabling the key.
resource "aws_kms_key" "aurora" {
  description             = "Forge prod: the Aurora cluster"
  multi_region            = true
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "aurora" {
  name          = module.constants.prod_aurora_key_alias
  target_key_id = aws_kms_key.aurora.key_id
}

# The key prod OpenBao seals its storage with. Dev and staging get theirs from
# the platform module, which destroys it with the stage. Prod's lives here
# because OpenBao's storage, in the Aurora cluster, outlives the platform root in
# the cluster's final snapshot and its DR copies, and is unreadable without
# this key.
#
# Multi-region because the flag is fixed when a key is created, and changing
# the key later means migrating a running OpenBao to a new seal. After losing
# us-east-2, the platform root applied in the DR region unseals the Global
# Database secondary's copy of OpenBao with a replica of this key. FIL-1303 adds
# that replica, the same alias on it in the DR region (an alias does not follow
# a key into its replicas), and the same deletion guard as the Aurora key's.
resource "aws_kms_key" "openbao_seal" {
  description             = "Forge prod: the OpenBao seal"
  multi_region            = true
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "openbao_seal" {
  name          = module.constants.prod_openbao_seal_key_alias
  target_key_id = aws_kms_key.openbao_seal.key_id
}

output "provision_repository_url" {
  value = module.ecr.provision_repository_url
}
