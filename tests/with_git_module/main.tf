terraform {
  required_version = ">= 1.0"
}

# Fetched from git by the extension: a tag ref on a forced `git::` source.
module "label" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git?ref=0.25.0"

  namespace = "test"
  name      = "rules-terraform"
  stage     = "ci"
}

# The GitHub shorthand for the same repository and ref. Both spellings land
# on one commit, so the pool holds one checkout with a target per spelling.
module "label_shorthand" {
  source = "github.com/cloudposse/terraform-null-label?ref=0.25.0"

  namespace = "test"
  name      = "rules-terraform"
  stage     = "ci"
}

# A `//subdir` of the same checkout. `exports/context.tf` is a module in its
# own right, and one that names a registry module, so a git module's own
# references are followed the way a registry module's are.
module "label_exports" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git//exports?ref=0.25.0"

  namespace = "test"
  name      = "rules-terraform"
  stage     = "ci"
}

# The same tag by its commit id: the only pin that needs no lookup at all.
module "label_commit" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git?ref=488ab91e34a24a86957e397d9f7262ec5925586a"

  namespace = "test"
  name      = "rules-terraform"
  stage     = "ci"
}

output "id" {
  description = "The label module's canonical id."
  value       = module.label.id
}

output "shorthand_id" {
  description = "The same id through the shorthand spelling."
  value       = module.label_shorthand.id
}
