terraform {
  required_version = ">= 1.6"

  required_providers {
    null = {
      # Fully-qualify with the registry host so the lock file and the
      # `terraform` module extension agree on the source string.
      source  = "registry.terraform.io/hashicorp/null"
      version = "3.2.4"
    }
  }
}

# Reaching up into the shared library. The root module is three directories
# deep, so every source climbs with `../../../` — the layout that only works
# because the built module tree is rooted at the ancestor this environment and
# `modules/` share.
module "compute" {
  source = "../../../modules/compute"

  cidr_block     = var.cidr_block
  instance_count = var.instance_count
}

module "storage" {
  source = "../../../modules/storage"

  bucket_name = "${var.environment}-app-assets"
}
