terraform {
  required_version = ">= 1.4"
}

module "network" {
  source = "./modules/network"

  network_name = var.network_name
}

module "storage" {
  source = "./modules/storage"

  storage_name = var.storage_name
  network_id   = module.network.network_id
}

output "network_id" {
  description = "The network ID from the network module"
  value       = module.network.network_id
}

output "network_name" {
  description = "The network name from the network module"
  value       = module.network.network_name
}

output "storage_id" {
  description = "The storage ID from the storage module"
  value       = module.storage.storage_id
}

output "storage_name" {
  description = "The storage name from the storage module"
  value       = module.storage.storage_name
}
