variable "stage" {
  type = string
}

variable "force_destroy" {
  description = "Delete each bucket's contents along with the bucket. Set on non-prod stages, which have to come apart cleanly."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Refuse DeleteTable on the delegator's tables. Same trade as point_in_time_recovery: continuous backups make a wrong write recoverable, this makes the table itself hard to lose in the first place, and a stage meant to be thrown away wants neither."
  type        = bool
  default     = true
}

variable "point_in_time_recovery" {
  description = "Continuous backups on the delegator's tables. The allow list gates which storage providers may register, so losing it costs a re-approval of every provider; a stage that is meant to be thrown away does not pay for that."
  type        = bool
  default     = true
}

variable "versioning" {
  description = "Keep previous versions of Sprue's objects for pitr_window_days, so the buckets can be read as of any point the database can be restored to. A stage meant to be thrown away skips it: a versioned bucket cannot be emptied with a plain recursive delete."
  type        = bool
  default     = true
}

variable "pitr_window_days" {
  description = "How long noncurrent object versions are kept, and the delegator's tables' point-in-time recovery period. The platform passes the stage's database recovery window, so all three can be restored to the same point."
  type        = number

  validation {
    condition     = var.pitr_window_days >= 1 && var.pitr_window_days <= 35
    error_message = "pitr_window_days must be between 1 and 35, the range DynamoDB point-in-time recovery accepts."
  }
}
