terraform {
  required_version = ">= 1.0"
}

# Configuration keyed on the workspace, the common way to run one root
# against several environments. `terraform.workspace` is a known value at
# validate time, so this is only valid in a workspace the map names: the
# default workspace fails, and each named one is checked by its own test.
locals {
  config = {
    dev  = { size = "small" }
    prod = { size = "large" }
  }
  current = local.config[terraform.workspace]
}

output "size" {
  value = local.current.size
}
