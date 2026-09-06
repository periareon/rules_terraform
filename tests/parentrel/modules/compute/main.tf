terraform {
  required_version = ">= 1.0"
}

# A sibling inside the same shared library, reached with `../`. Nothing in the
# root module's BUILD file mentions `network` — it arrives through this
# module's own `deps`, and the init aspect follows the closure.
module "network" {
  source = "../network"

  cidr_block = var.cidr_block
}

output "subnet_cidrs" {
  description = "Subnets the instances would be placed in."
  value       = module.network.subnet_cidrs
}
