terraform {
  required_version = ">= 1.0"

  required_providers {
    null = {
      source = "registry.terraform.io/hashicorp/null"
      # Pinned exactly to keep the diff-test golden stable.
      version = "3.2.4"
    }
  }
}

module "mymod" {
  source = "./mymod"

  name = var.name
}

resource "null_resource" "example" {
  triggers = {
    greeting = module.mymod.greeting
  }
}

output "greeting" {
  description = "Greeting from the module"
  value       = module.mymod.greeting
}

output "resource_id" {
  description = "ID of the null resource"
  value       = null_resource.example.id
}
