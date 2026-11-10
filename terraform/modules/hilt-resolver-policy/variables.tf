variable "ingot_hostname_suffix" {
  description = "Stage's content-domain suffix, matching the Ingot identity derived during appliance onboarding."
  type        = string

  validation {
    condition = length(var.ingot_hostname_suffix) <= 253 && can(regex(
      "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$",
      var.ingot_hostname_suffix
    ))
    error_message = "The Ingot hostname suffix must be a literal lowercase DNS name, without globs, ports, paths or commas."
  }
}

variable "appliance_key_names" {
  description = "Live provisioned transit-key names from the platform output. An empty list permits no external did:web identity."
  type        = list(string)

  validation {
    condition = alltrue([
      for name in var.appliance_key_names :
      can(regex("^appliance-unseal-[a-z0-9]([a-z0-9-]*[a-z0-9])?$", name))
    ])
    error_message = "Every appliance key must have the appliance-unseal- prefix and one literal lowercase region label, without globs, paths, ports or commas."
  }
}
