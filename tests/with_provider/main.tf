terraform {
  required_version = ">= 1.0"

  required_providers {
    null = {
      # Fully-qualify the source so both Terraform (default registry
      # terraform.io) and OpenTofu (default registry opentofu.org) resolve
      # to the same lock entry.
      source = "registry.terraform.io/hashicorp/null"
      # Pinned exactly so the checked-in lock file (and the diff-test golden
      # generated from real `terraform providers lock`) don't drift as new
      # 3.x versions get published upstream.
      version = "3.2.4"
    }
  }
}

resource "null_resource" "example" {
  triggers = {
    always_run = "${timestamp()}"
  }

  provisioner "local-exec" {
    command = "echo 'Hello from Terraform!'"
  }
}

output "example_id" {
  description = "The ID of the null resource"
  value       = null_resource.example.id
}
