terraform {
  required_version = ">= 1.0"
}

# A version constraint rather than an exact pin: the extension resolves it
# against the registry once and records the version it chose as a fact, so
# every later evaluation installs the same release until an upgrade is asked
# for. `~> 0.24` names 0.25.0 today and would name 0.26.0 the day it ships.
module "label" {
  source  = "cloudposse/label/null"
  version = "~> 0.24"

  namespace = "test"
  name      = "rules-terraform"
  stage     = "ci"
}

output "id" {
  description = "The label module's canonical id."
  value       = module.label.id
}
