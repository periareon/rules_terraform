output "subnet_cidrs" {
  description = "Subnets the instances were placed in."
  value       = module.network.subnet_cidrs
}

output "instance_ids" {
  description = "One id per instance."
  value       = null_resource.instance[*].id
}
