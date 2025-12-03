terraform {
  required_version = ">= 1.0"
}

module "mymod" {
  source = "./mymod"

  name = var.name
}

output "greeting" {
  description = "Greeting from the cross-package module"
  value       = module.mymod.greeting
}
