terraform {
  required_version = ">= 1.6"

  required_providers {
    # Reusable modules name the providers they use but leave the version to
    # the root module, which is what the lock file pins.
    null = {
      source = "registry.terraform.io/hashicorp/null"
    }
  }
}

# A sibling inside the same shared library, reached with `../`. Nothing in the
# environment's BUILD file mentions `network` — it arrives through this
# module's own `deps`, and the init aspect follows the closure.
module "network" {
  source = "../network"

  cidr_block   = var.cidr_block
  subnet_count = var.subnet_count
}

resource "null_resource" "instance" {
  count = var.instance_count

  triggers = {
    subnet = module.network.subnet_cidrs[count.index % var.subnet_count]
  }
}
