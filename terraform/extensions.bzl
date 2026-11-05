"""The `terraform` bzlmod extension.

One extension, two tag classes:

* `toolchain` — pins the Terraform release the build uses, any release,
  not only the ones shipped in `//terraform/private:versions.bzl`. Root
  module only; without it the newest shipped release is used. The
  extension always materializes `@terraform_toolchains`, a hub declaring a
  toolchain per platform for that release, and `@terraform`, the CLI hub.
  rules_terraform's own `MODULE.bazel` `use_repo`s the toolchain hub and
  `register_toolchains`s it, so downstream users get toolchain resolution
  for free.
* `deps` — the providers a lock file pins and the registry and git modules
  some directories' `module` blocks name, as one hub per tag. Fetched
  archives go into one pool shared by every hub, keyed by what the archive
  is rather than who asked for it; each hub is an alias layer over that pool.

The body is `//engine:extension_impl.bzl`, shared with the other engine.
Everything Terraform-specific is in `//terraform/private:engine.bzl`.
"""

load("//engine:extension_impl.bzl", "deps_tag_class", "run_extension")
load("//engine:toolchain_extension.bzl", "toolchain_tag_class")
load("//terraform/private:engine.bzl", "TERRAFORM_ENGINE")

def _terraform_impl(module_ctx):
    return run_extension(module_ctx, engine = TERRAFORM_ENGINE)

terraform = module_extension(
    doc = """The Terraform extension: a `toolchain` tag pins the engine release,
    `deps` tags describe a module's external dependencies. Always
    materializes `@terraform_toolchains` and `@terraform`; `deps` defaults to
    `registry.terraform.io`.""",
    implementation = _terraform_impl,
    tag_classes = {
        "deps": deps_tag_class(TERRAFORM_ENGINE.registry),
        "toolchain": toolchain_tag_class(TERRAFORM_ENGINE.name),
    },
)
