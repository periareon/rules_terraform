terraform {
  required_version = ">= 1.6"

  required_providers {
    null = {
      source = "registry.terraform.io/hashicorp/null"
    }
  }
}

resource "null_resource" "bucket" {
  triggers = {
    name = var.bucket_name
  }
}
