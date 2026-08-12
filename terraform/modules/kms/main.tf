# One customer-managed key per stage, sealing OpenBao.
#
# Using it as OpenBao's seal is what removes the unseal key from the design
# entirely. smelt keeps a Shamir key in 1Password and runs a sidecar that polls
# and unseals; here KMS unwraps the barrier key on startup, so a replaced task
# comes back ready with no operator step and no plaintext key anywhere.
#
# SecureString parameters deliberately do not use this key. It dies with the
# stage, and a key in PendingDeletion stops serving decryption at once, so
# every secret the stage ever minted would become unreadable the moment it came
# down. They take the account's AWS-managed SSM key instead, which cannot be
# deleted. What this key protects therefore dies with the stage by design:
# OpenBao's storage lives in the same RDS instance and goes at the same time.

locals {
  name = "fc-${var.stage}"
}

resource "aws_kms_key" "this" {
  description         = "Forge ${var.stage}: the OpenBao seal"
  enable_key_rotation = true

  # A destroyed key makes OpenBao's storage permanently unreadable, so a
  # protected stage takes the widest window AWS allows. A stage meant to come
  # apart takes the narrowest, since the key is the last thing left standing
  # after its destroy.
  deletion_window_in_days = var.deletion_window_in_days
}

resource "aws_kms_alias" "this" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.this.key_id
}
