# Variables for the simple example
variable "environment" {
  description = "The environment name"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "The name of the project"
  type        = string
  default     = "simple-example"
}
