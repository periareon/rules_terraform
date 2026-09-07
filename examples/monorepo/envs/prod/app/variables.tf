variable "environment" {
  description = "Environment this root module manages."
  type        = string
  default     = "prod"
}

variable "cidr_block" {
  description = "Address space for this environment."
  type        = string
  default     = "10.20.0.0/16"
}

variable "instance_count" {
  description = "How many instances this environment runs."
  type        = number
  default     = 3
}
