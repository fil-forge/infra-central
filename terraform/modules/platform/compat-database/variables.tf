variable "stage" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "availability_zones" {
  description = "One subnet per zone, from the network module so both agree. At most four, because the subnets take /20 indexes 12 to 15."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2 && length(var.availability_zones) <= 4
    error_message = "The cluster needs two to four availability zones."
  }
}

variable "lambda_security_group_id" {
  description = "The provision Lambda's group. The seed phase connects through it to create the database and roles."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed key encrypting the cluster and its snapshots."
  type        = string
}

variable "sites" {
  description = "The stage's compatibility server sites from the shared constants module's compat_server_sites. Each private_ip is admitted on 5432. modules/compat-vpn validates the addresses."
  type = map(object({
    public_ip  = string
    private_ip = string
  }))

  validation {
    condition     = length(var.sites) > 0
    error_message = "The cluster needs at least one compatibility server site: it is reached through the stage's VPN gateway, which the regional bootstrap creates only for a stage with sites. Add one to compat_server_sites in modules/shared/constants and apply the regional bootstrap first."
  }
}

variable "instance_count" {
  description = "1 is a writer alone; 2 adds a reader in another zone."
  type        = number
}

variable "backup_retention_days" {
  description = "Aurora's floor is 1; automated backups cannot be turned off."
  type        = number
}

variable "protect" {
  description = "Deletion protection and a final snapshot. Off for a cluster holding test data only."
  type        = bool
}
