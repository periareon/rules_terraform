terraform {
  required_version = ">= 1.6"

  required_providers {
    null = {
      # Fully-qualify with the registry host so the lock file and the
      # extension agree on the source string.
      source  = "registry.terraform.io/hashicorp/null"
      version = "3.2.4"
    }
  }
}

module "greeter" {
  source = "./modules/greeter"

  name = var.name
}

resource "null_resource" "example" {
  triggers = {
    greeting = module.greeter.message
  }
}
