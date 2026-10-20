terraform {
  required_version = ">= 1.6"

  required_providers {
    null = {
      # Pinned to `registry.opentofu.org` because OpenTofu 1.10+ silently
      # rewrites `registry.terraform.io/hashicorp/*` entries to their
      # opentofu.org equivalents at init time (their release hashes differ,
      # so the rewrite invalidates any pre-installed providers under the
      # terraform.io path and forces a network fetch — which the macOS
      # sandbox blocks under `bazel test`). The MODULE.bazel `terraform.providers`
      # tag fetches from the same registry so on-disk layout matches.
      source  = "registry.opentofu.org/hashicorp/null"
      version = "3.2.4"
    }
  }
}

module "greeter" {
  source = "./modules/greeter"

  name = var.name
}

# A registry module, fetched by the `tofu.deps` tag in MODULE.bazel and installed by
# the init aspect at `.terraform/modules/label`, so `tofu init` never contacts
# the registry.
module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  namespace = "example"
  stage     = "tofu"
  name      = var.name
}

resource "null_resource" "example" {
  triggers = {
    greeting = module.greeter.message
  }
}
