# Simple Terraform example with no providers
terraform {
  required_version = ">= 1.0"
}

# Output the environment and project name
output "environment" {
  description = "The environment name"
  value       = var.environment
}

output "project_name" {
  description = "The project name"
  value       = var.project_name
}
