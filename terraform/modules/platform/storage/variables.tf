variable "stage" {
  type = string
}

variable "force_destroy" {
  description = "Delete each bucket's contents along with the bucket. Set on non-prod stages, which have to come apart cleanly."
  type        = bool
  default     = false
}

variable "point_in_time_recovery" {
  description = "Continuous backups on the delegator's tables. The allow list gates which storage providers may register, so losing it costs a re-approval of every provider; a stage that is meant to be thrown away does not pay for that."
  type        = bool
  default     = true
}
