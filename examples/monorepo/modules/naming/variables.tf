variable "namespace" {
  description = "Organisation or team prefix for every name."
  type        = string
  default     = "acme"
}

variable "environment" {
  description = "Environment the names belong to."
  type        = string
}

variable "name" {
  description = "Component name."
  type        = string
  default     = "app"
}
