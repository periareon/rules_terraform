terraform {
  required_version = ">= 1.0"
}

module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  namespace = "test"
  name      = "rules-terraform"
  stage     = "ci"
}

output "id" {
  description = "The label module's canonical id."
  value       = module.label.id
}
