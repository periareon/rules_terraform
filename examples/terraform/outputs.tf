output "greeting" {
  description = "The greeting rendered by the greeter module."
  value       = module.greeter.message
}

output "resource_id" {
  description = "The null_resource id — changes whenever the greeting changes."
  value       = null_resource.example.id
}
