variable "stage" {
  type = string
}

variable "deletion_window_in_days" {
  description = "Days the key sits in PendingDeletion after a destroy. AWS accepts 7 to 30 and offers no way to delete a key outright."
  type        = number
  default     = 30
}
