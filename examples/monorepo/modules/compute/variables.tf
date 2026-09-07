variable "cidr_block" {
  description = "Address space handed down to the network module."
  type        = string
}

variable "subnet_count" {
  description = "How many subnets to spread instances across."
  type        = number
  default     = 2
}

variable "instance_count" {
  description = "How many instances to place."
  type        = number
  default     = 2
}
