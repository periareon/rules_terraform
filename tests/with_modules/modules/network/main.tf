terraform {
  required_version = ">= 1.4"
}

resource "terraform_data" "network" {
  input = var.network_name
}

output "network_id" {
  description = "The network resource ID"
  value       = terraform_data.network.id
}

output "network_name" {
  description = "The network name"
  value       = var.network_name
}
