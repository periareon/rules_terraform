"""OpenTofu bzlmod extensions.

Two extensions live here:

* `tofu_toolchains` — materializes a hub covering the OpenTofu releases
  shipped in `//tofu/private:versions.bzl` plus any a `version` tag asks
  for; `//tofu/settings:version` picks one, empty meaning the default.
* `tofu` — the `deps` tag class mirroring the `terraform` extension's,
  defaulting to `registry.opentofu.org`. OpenTofu's registry
  serves its own builds of the hashicorp providers, so a lock written by
  `tofu` carries their hashes and must be resolved against that registry.
"""

# buildifier: disable=bzl-visibility
load("//terraform/private:cli.bzl", "tofu_cli_hub")

# buildifier: disable=bzl-visibility
load("//terraform/private:extension_impl.bzl", "deps_tag_class", "run_extension")

# buildifier: disable=bzl-visibility
load("//terraform/private:toolchain_extension.bzl", "toolchains_extension_impl", "version_tag_class")
load(
    "//tofu/private:versions.bzl",
    "TOFU_DEFAULT_VERSION",
    "TOFU_VERSIONS",
)

_HUB_NAME = "tofu_toolchains"
_TOFU_REGISTRY = "registry.opentofu.org"

def _tofu_toolchains_impl(module_ctx):
    return toolchains_extension_impl(
        module_ctx,
        engine = "tofu",
        hub_name = _HUB_NAME,
        toolchain_type = "@rules_terraform//tofu:toolchain_type",
        version_flag = "@rules_terraform//tofu/settings:version",
        versions = TOFU_VERSIONS,
        default_version = TOFU_DEFAULT_VERSION,
        binary_name = "tofu",
        archive_prefix = "tofu",
        sha256sums_url = lambda v: "https://github.com/opentofu/opentofu/releases/download/v{v}/tofu_{v}_SHA256SUMS".format(v = v),
        download_url = lambda v, p: "https://github.com/opentofu/opentofu/releases/download/v{v}/tofu_{v}_{p}.zip".format(v = v, p = p),
        # `@tofu` — `bazel run @tofu -- <cmd>` chdirs to $BUILD_WORKING_DIRECTORY
        # and execs the resolved toolchain `tofu` binary with the user's argv.
        declare_cli_hub = lambda: tofu_cli_hub(name = "tofu"),
    )

tofu_toolchains = module_extension(
    doc = """Materializes the `@tofu_toolchains` hub: the releases shipped in
    `//tofu/private:versions.bzl` plus any a `version` tag asks for, and the
    `@tofu` CLI hub.""",
    implementation = _tofu_toolchains_impl,
    tag_classes = {"version": version_tag_class("tofu")},
)

def _tofu_impl(module_ctx):
    return run_extension(module_ctx, registry_default = _TOFU_REGISTRY)

tofu = module_extension(
    doc = """Bzlmod extension for an OpenTofu module's external dependencies:
    the same `deps` tag class as the `terraform` extension, defaulting to
    `registry.opentofu.org`. An OpenTofu-only repository needs nothing from
    `//terraform:extensions.bzl`.""",
    implementation = _tofu_impl,
    tag_classes = {"deps": deps_tag_class(_TOFU_REGISTRY)},
)
