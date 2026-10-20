output "subnet_cidrs" {
  description = "Subnets allocated by the shared network module, two modules deep."
  value       = module.compute.subnet_cidrs
}

output "name" {
  description = "Canonical name from the shared naming library, which wraps a registry module."
  value       = module.naming.id
}

output "bucket_name" {
  description = "Bucket created by the shared storage module."
  value       = module.storage.bucket_name
}
