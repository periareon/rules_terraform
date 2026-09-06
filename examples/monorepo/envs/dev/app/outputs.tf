output "subnet_cidrs" {
  description = "Subnets allocated by the shared network module, two modules deep."
  value       = module.compute.subnet_cidrs
}

output "bucket_name" {
  description = "Bucket created by the shared storage module."
  value       = module.storage.bucket_name
}
