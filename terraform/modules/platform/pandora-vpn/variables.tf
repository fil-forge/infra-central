variable "stage" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "sites" {
  description = "The stage's compatibility server appliances, keyed by region label: each one's static public IPv4 and the private /32 its database traffic is source-NATed to. From the shared constants module's pandora_sites."
  type = map(object({
    public_ip  = string
    private_ip = string
  }))

  validation {
    condition = alltrue([
      for site in values(var.sites) : can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", site.public_ip))
    ])
    error_message = "Each site's public_ip must be a bare IPv4 address, without a prefix length."
  }

  validation {
    condition = alltrue([
      for site in values(var.sites) :
      try(endswith(site.private_ip, "/32") && cidrcontains(var.private_cidr, site.private_ip), false)
    ])
    error_message = "Each site's private_ip must be a /32 inside private_cidr."
  }

  validation {
    condition     = length(distinct([for site in values(var.sites) : site.private_ip])) == length(var.sites)
    error_message = "Two sites share a private_ip, so the VPN routes and the security group could not tell them apart."
  }
}

variable "private_cidr" {
  description = "The block every site's private /32 comes from. Outside the VPC, so it can never clash with an address there."
  type        = string
}
