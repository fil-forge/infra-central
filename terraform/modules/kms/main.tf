# One customer-managed key per stage, used for two things: encrypting every
# SecureString parameter the provision Lambda writes, and sealing OpenBao.
#
# Using it as OpenBao's seal is what removes the unseal key from the design
# entirely. smelt keeps a Shamir key in 1Password and runs a sidecar that polls
# and unseals; here KMS unwraps the barrier key on startup, so a replaced task
# comes back ready with no operator step and no plaintext key anywhere.

locals {
  name = "fc-${var.stage}"
}

resource "aws_kms_key" "this" {
  description         = "Forge ${var.stage}: SSM parameter encryption and the OpenBao seal"
  enable_key_rotation = true

  # A destroyed key makes every SecureString parameter and OpenBao's entire
  # storage permanently unreadable, so the window to catch a mistake is as wide
  # as AWS allows.
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "this" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.this.key_id
}
