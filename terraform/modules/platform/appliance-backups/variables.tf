variable "stage" {
  type = string
}

variable "account_id" {
  description = "Makes the bucket name globally unique."
  type        = string
}

variable "regions" {
  description = "Region labels of the appliances that write backups, from appliance_regions. Each one gets a writer user; a label that leaves the list loses its user and its key on the next apply."
  type        = list(string)
}

variable "retention_days" {
  description = "How long each backup is locked in compliance mode, and then kept. No credential can delete or overwrite a backup before this many days have passed."
  type        = number

  validation {
    condition     = var.retention_days >= 1
    error_message = "retention_days must be at least 1."
  }
}
