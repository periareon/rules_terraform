terraform {
  required_version = ">= 1.6"

  required_providers {
    null = {
      source  = "registry.terraform.io/hashicorp/null"
      version = "3.2.4"
    }
  }
}

variable "name" {
  type    = string
  default = "unset"
}

resource "null_resource" "example" {
  triggers = {
    name = var.name
  }
}

output "resource_name" {
  value = null_resource.example.triggers.name
}
