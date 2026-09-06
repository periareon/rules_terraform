terraform {
  required_version = ">= 1.0"
}

module "wrapper" {
  source = "../../modules/wrapper"
}

output "id" {
  description = "Proves the nested registry module resolved."
  value       = module.wrapper.id
}
