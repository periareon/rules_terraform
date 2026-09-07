variable "cidr_block" {
  description = "Address space to carve subnets out of."
  type        = string
}

variable "subnet_count" {
  description = "How many equally-sized subnets to allocate."
  type        = number
  default     = 2
}
