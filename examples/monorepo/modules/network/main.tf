terraform {
  required_version = ">= 1.6"
}

# Pure computation — no provider, no resources. A module like this is the
# cheapest thing in a shared library and the most widely reused.
locals {
  subnet_cidrs = [for i in range(var.subnet_count) : cidrsubnet(var.cidr_block, 8, i)]
}
