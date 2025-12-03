terraform {
  required_version = ">= 1.0"

  required_providers {
    sops = {
      source = "registry.terraform.io/carlpett/sops"
      # Pinned exactly so the diff-test goldens stay stable as new 1.x
      # versions are published upstream.
      version = "1.2.0"
    }
  }
}

# Declaring the provider without configuring resources is enough to exercise
# the non-HashiCorp registry fetch + init path through `terraform validate`.
provider "sops" {}

output "provider_ok" {
  description = "Marker output so validate has something to look at."
  value       = "sops provider wired"
}
