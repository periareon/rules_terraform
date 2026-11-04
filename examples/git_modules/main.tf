terraform {
  required_version = ">= 1.5.7"
}

# A `//subdir` module at a tag. `modules/_user_data` reads its templates
# from `../../templates/`, two directories above itself in the repository:
# it only works because the whole repository is installed and the module
# directory is the subdirectory within it, as `terraform init` lays it out.
module "user_data" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git//modules/_user_data?ref=v21.6.1"

  cluster_name               = "example"
  cluster_endpoint           = "https://example.eks.amazonaws.com"
  cluster_auth_base64        = "ZXhhbXBsZQ=="
  cluster_service_cidr       = "172.20.0.0/16"
  enable_bootstrap_user_data = true
}

# A branch. It is resolved to the commit it points at the first time; after
# that the recorded commit is what every evaluation uses, until
# `RULES_TERRAFORM_UPGRADE=1 bazel fetch //...` asks again. (This example
# runs with the lockfile off, so each fresh evaluation is a first time.)
module "label_main" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git?ref=main"

  namespace = "example"
  name      = "branch"
}

# No ref at all: the remote's default branch, treated the same way.
module "label" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git"

  namespace = "example"
  name      = "head"
}

output "user_data_length" {
  description = "Size of the rendered user data, which exists only if the templates were installed."
  value       = length(module.user_data.user_data)
}

output "ids" {
  description = "The two labels' canonical ids."
  value       = [module.label_main.id, module.label.id]
}
