variable "stage" {
  description = "Deployment stage, e.g. dev or prod. Namespaces every resource."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must leave room for four /20 subnets."
  type        = string
  default     = "10.20.0.0/16"
}
