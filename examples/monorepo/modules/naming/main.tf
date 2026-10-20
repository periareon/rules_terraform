terraform {
  required_version = ">= 1.6"
}

# A shared library that wraps a *registry* module. The `module` block that
# reaches the registry lives here, in the library, not in any environment —
# which is why `//modules/naming` is the directory listed in the `deps` tag's
# `roots` in MODULE.bazel, and why this library depends on the hub. The
# environments only see `module.naming.id`.
module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  namespace = var.namespace
  stage     = var.environment
  name      = var.name
}
