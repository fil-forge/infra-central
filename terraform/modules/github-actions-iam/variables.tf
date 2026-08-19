variable "repository" {
  description = "owner/repo whose workflows may assume these roles. The `sub` claim carries it, so a workflow in any other repository cannot assume either role however the trust policy is otherwise satisfied."
  type        = string
}

variable "repository_subject_prefix" {
  description = <<-EOT
    The `repo:` segment of the `sub` claim GitHub actually mints for this repository, without the trailing event part. Either `repo:<owner>/<repo>` or, for a repository created, renamed or transferred after 2026-07-15, the immutable `repo:<owner>@<owner_id>/<repo>@<repo_id>`.

    Read it rather than composing it, because which shape a repository gets is not derivable from its name:

        gh api /repos/<owner>/<repo>/actions/oidc/customization/sub -q .sub_claim_prefix
  EOT
  type        = string
}

variable "state_bucket_name" {
  description = "The state bucket these roles get access to, from the tfstate module's output. Both roles are granted this bucket and no other."
  type        = string
}

variable "state_key_prefixes" {
  description = "Key prefixes in the state bucket the roles may touch, one per stage the workflow deploys. Bootstrap state is deliberately excluded: it is applied by an operator from a laptop, so no CI role needs to write it."
  type        = list(string)
  default     = ["dev"]
}

variable "name_prefix" {
  description = "Prefix for both role names, giving forge-central-ci-plan and forge-central-ci-apply."
  type        = string
  default     = "forge-central"
}

variable "account_id" {
  description = "Account these roles live in, used to scope the apply role's IAM writes to the fc-* roles this project creates. Passed in rather than read from aws_caller_identity, so a bootstrap applied with the wrong credentials fails on the provider's allowed_account_ids guard instead of quietly writing a policy for the wrong account."
  type        = string
}
