terraform {
  required_version = ">= 1.4"
}

resource "terraform_data" "storage" {
  input = "${var.storage_name}-${var.network_id}"
}

output "storage_id" {
  description = "The storage resource ID"
  value       = terraform_data.storage.id
}

output "storage_name" {
  description = "The storage name"
  value       = var.storage_name
}
