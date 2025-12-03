terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "registry.terraform.io/hashicorp/aws"
      version = ">= 5.79.0"
    }
    null = {
      source  = "registry.terraform.io/hashicorp/null"
      version = "~> 3.0"
    }
  }
}

resource "null_resource" "example" {
  triggers = {
    name = var.vpc_name
  }
}

output "vpc_name" {
  description = "The VPC name"
  value       = var.vpc_name
}
