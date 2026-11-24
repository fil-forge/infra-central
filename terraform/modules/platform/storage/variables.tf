variable "stage" {
  type = string
}

variable "force_destroy" {
  description = "Delete each bucket's contents along with the bucket. Set on non-prod stages, which have to come apart cleanly."
  type        = bool
  default     = false
}

variable "versioning" {
  description = "Keep previous versions of Sprue's objects for pitr_window_days, so the buckets can be read as of any point the database can be restored to. A stage meant to be thrown away skips it: a versioned bucket cannot be emptied with a plain recursive delete."
  type        = bool
  default     = true
}

variable "pitr_window_days" {
  description = "How long noncurrent object versions are kept. The platform passes the stage's database recovery window, so the buckets can be read as of any point the database can be restored to."
  type        = number

  validation {
    condition     = var.pitr_window_days >= 1 && var.pitr_window_days <= 35
    error_message = "pitr_window_days must be between 1 and 35, the range the database's backup retention accepts."
  }
}
