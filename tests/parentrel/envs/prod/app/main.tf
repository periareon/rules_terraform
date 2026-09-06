terraform {
  required_version = ">= 1.0"
}

# The layout this fixture exists for: a per-environment root module several
# directories deep reaching up into a shared module library that no single root
# module can own.
module "compute" {
  source = "../../../modules/compute"

  cidr_block = "10.0.0.0/16"
}

output "subnet_cidrs" {
  description = "Subnets from the shared library, two modules deep."
  value       = module.compute.subnet_cidrs
}
