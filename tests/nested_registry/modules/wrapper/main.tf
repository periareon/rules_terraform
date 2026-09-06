terraform {
  required_version = ">= 1.0"
}

# The registry module is referenced from here, one level down from the root
# module — so Terraform addresses it as `wrapper.label`, not `label`.
module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  namespace = "test"
  name      = "nested"
  stage     = "ci"
}

output "id" {
  description = "The label module's canonical id, re-exported."
  value       = module.label.id
}
