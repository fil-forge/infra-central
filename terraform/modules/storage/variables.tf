variable "stage" {
  type = string
}

variable "point_in_time_recovery" {
  description = "The allow list gates which storage providers may register; losing it means re-approving every provider."
  type        = bool
  default     = true
}
