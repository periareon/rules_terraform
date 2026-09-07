terraform {
  required_version = ">= 1.0"
}

# Provider-free on purpose: the fixture is about where files land in the module
# tree, so it computes with builtins rather than pulling a provider into every
# test run.
output "subnet_cidrs" {
  description = "One CIDR per subnet, carved out of var.cidr_block."
  value       = [for i in range(var.subnet_count) : cidrsubnet(var.cidr_block, 8, i)]
}
