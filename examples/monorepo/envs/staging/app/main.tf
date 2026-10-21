terraform {
  required_version = ">= 1.6"

  # A different provider set from dev and prod: staging also uses `random`.
  # That is why it keeps its own lock file next to this file, and its own
  # `deps` tag in MODULE.bazel, instead of sharing the repo-wide one. `null` still comes out of the same pooled archive the other
  # environments use; only the lock that vouches for it is different.
  required_providers {
    null = {
      source  = "registry.terraform.io/hashicorp/null"
      version = "3.2.4"
    }
    random = {
      source  = "registry.terraform.io/hashicorp/random"
      version = "3.7.2"
    }
  }
}

module "compute" {
  source = "../../../modules/compute"

  cidr_block     = var.cidr_block
  instance_count = var.instance_count
}

module "storage" {
  source = "../../../modules/storage"

  bucket_name = "${module.naming.id}-assets"
}

module "naming" {
  source = "../../../modules/naming"

  environment = var.environment
}

# A registry module named directly from a root module, alongside the one the
# `naming` library wraps. This directory is in the `staging` tag's `roots`, the
# library's in `shared`'s; both ask for the same version, so the pool fetches the
# archive once and the init aspect installs it under each `module` block's key.
module "tags" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  namespace = "acme"
  stage     = var.environment
  name      = "owner"

  tags = {
    Team = "platform"
  }
}

resource "random_pet" "release" {
  keepers = {
    environment = var.environment
  }
}

resource "null_resource" "deploy" {
  triggers = {
    release = random_pet.release.id
    owner   = module.tags.id
  }
}
