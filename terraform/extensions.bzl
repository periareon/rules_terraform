"""Terraform bzlmod extensions.

Two extensions live here:

* `terraform_toolchains` — materializes ONE hub repo (`@terraform_toolchains`)
  declaring a toolchain per (version, platform) for the releases shipped in
  `//terraform/private:versions.bzl` and any a `version` tag asks for.
  rules_terraform's own `MODULE.bazel` `use_repo`s the hub and
  `register_toolchains`s it, so downstream users get toolchain resolution
  for free. `//terraform/settings:version` picks the release; empty means
  the default. See `//terraform/private:toolchain_extension.bzl`.
* `terraform` — carries the `deps` tag class: the providers a lock file
  pins and the registry modules some directories' `module` blocks name,
  as one hub per tag.
  Fetched archives go into one pool shared by every hub, keyed by what the
  archive is rather than who asked for it; each hub is an alias layer over
  that pool. The body lives in `//terraform/private:extension_impl.bzl`,
  shared with the `tofu` extension.
"""

load("//terraform/private:cli.bzl", "terraform_cli_hub")
load("//terraform/private:extension_impl.bzl", "deps_tag_class", "run_extension")
load("//terraform/private:toolchain_extension.bzl", "toolchains_extension_impl", "version_tag_class")
load("//terraform/private:versions.bzl", "TERRAFORM_DEFAULT_VERSION", "TERRAFORM_VERSIONS")

_TERRAFORM_REGISTRY = "registry.terraform.io"

# Fixed hub name — since this extension takes no user config beyond
# `version` tags, we can bake it in. The corresponding `use_repo` /
# `register_toolchains` calls in rules_terraform's `MODULE.bazel` reference
# this exact name.
_HUB_NAME = "terraform_toolchains"

def _terraform_toolchains_impl(module_ctx):
    return toolchains_extension_impl(
        module_ctx,
        engine = "terraform",
        hub_name = _HUB_NAME,
        toolchain_type = "@rules_terraform//terraform:toolchain_type",
        version_flag = "@rules_terraform//terraform/settings:version",
        versions = TERRAFORM_VERSIONS,
        default_version = TERRAFORM_DEFAULT_VERSION,
        binary_name = "terraform",
        archive_prefix = "terraform",
        sha256sums_url = lambda v: "https://releases.hashicorp.com/terraform/{v}/terraform_{v}_SHA256SUMS".format(v = v),
        download_url = lambda v, p: "https://releases.hashicorp.com/terraform/{v}/terraform_{v}_{p}.zip".format(v = v, p = p),
        # `@terraform` — a one-target hub whose `bazel run @terraform -- <cmd>`
        # chdirs to $BUILD_WORKING_DIRECTORY and execs the resolved toolchain
        # `terraform` binary with the user's argv.
        declare_cli_hub = lambda: terraform_cli_hub(name = "terraform"),
    )

terraform_toolchains = module_extension(
    doc = """Materializes the `@terraform_toolchains` hub: the releases shipped
    in `//terraform/private:versions.bzl` plus any a `version` tag asks for,
    and the `@terraform` CLI hub.""",
    implementation = _terraform_toolchains_impl,
    tag_classes = {"version": version_tag_class("terraform")},
)

def _terraform_impl(module_ctx):
    return run_extension(module_ctx, registry_default = _TERRAFORM_REGISTRY)

terraform = module_extension(
    doc = """Bzlmod extension for a Terraform module's external dependencies:
    the providers its lock pins and the registry modules it names, one `deps`
    tag per hub. Defaults to `registry.terraform.io`; the `tofu` extension in
    `//tofu:extensions.bzl` is the same extension defaulting to
    `registry.opentofu.org`.""",
    implementation = _terraform_impl,
    tag_classes = {"deps": deps_tag_class(_TERRAFORM_REGISTRY)},
)
