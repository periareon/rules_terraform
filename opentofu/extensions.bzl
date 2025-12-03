"""OpenTofu bzlmod extensions.

Two extensions live here:

* `opentofu_toolchains` — no user-facing configuration. Materializes a
  hub covering every supported OpenTofu version, guarded by
  `target_settings` on `//opentofu/settings:version_<v>`.
* `opentofu` — `modules` tag class mirroring `terraform.modules(...)`
  but defaulting to `registry.opentofu.org`.
"""

load(
    "//opentofu/private:versions.bzl",
    "TOFU_VERSIONS",
)

# buildifier: disable=bzl-visibility
load("//terraform/private:cli.bzl", "opentofu_cli_hub")

# buildifier: disable=bzl-visibility
load("//terraform/private:modules_extension.bzl", "resolve_all_modules")

# buildifier: disable=bzl-visibility
load(
    "//terraform/private:toolchain_repo.bzl",
    "PLATFORM_TO_CONSTRAINTS",
    "terraform_toolchain_repository",
    "terraform_toolchain_repository_hub",
)

_HUB_NAME = "tofu_toolchains"
_OPENTOFU_REGISTRY = "registry.opentofu.org"

def _opentofu_toolchains_impl(module_ctx):
    toolchain_names = []
    toolchain_labels = {}
    exec_compatible_with = {}
    target_settings = {}

    for version, platforms in TOFU_VERSIONS.items():
        version_setting = "@rules_terraform//opentofu/settings:version_" + version.replace(".", "_")
        for platform, info in platforms.items():
            if platform not in PLATFORM_TO_CONSTRAINTS:
                continue
            repo_name = "{}_{}_{}".format(
                _HUB_NAME,
                version.replace(".", "_"),
                platform.replace("-", "_"),
            )
            terraform_toolchain_repository(
                name = repo_name,
                version = version,
                platform = platform,
                url = info["url"],
                integrity = info["integrity"],
                binary_name = "tofu",
            )
            toolchain_names.append(repo_name)
            toolchain_labels[repo_name] = "@" + repo_name
            exec_compatible_with[repo_name] = PLATFORM_TO_CONSTRAINTS[platform]
            target_settings[repo_name] = [version_setting]

    terraform_toolchain_repository_hub(
        name = _HUB_NAME,
        toolchain_labels = toolchain_labels,
        toolchain_names = toolchain_names,
        exec_compatible_with = exec_compatible_with,
        target_compatible_with = {},
        target_settings = target_settings,
        toolchain_type = str(Label("//opentofu:toolchain_type")),
    )

    # `@opentofu` — a one-target hub whose `bazel run @opentofu -- <cmd>`
    # chdirs to $BUILD_WORKING_DIRECTORY and execs the resolved toolchain
    # `tofu` binary with the user's argv. Downstream users add
    # `use_repo(opentofu_toolchains, "opentofu")` to reference it.
    opentofu_cli_hub(name = "opentofu")

    # Reproducible: every URL + integrity hash is vendored in
    # //opentofu/private:versions.bzl. No network at eval time; identical
    # inputs → identical repo declarations.
    return module_ctx.extension_metadata(reproducible = True)

opentofu_toolchains = module_extension(
    doc = "Materializes the `@tofu_toolchains` hub covering every supported OpenTofu version.",
    implementation = _opentofu_toolchains_impl,
)

def _opentofu_impl(module_ctx):
    return resolve_all_modules(module_ctx, registry_default = _OPENTOFU_REGISTRY)

_MODULES_TAG = tag_class(
    doc = """Live-resolves external OpenTofu registry modules from the
    `module { }` blocks in your root `.tf` files. Defaults to
    `registry.opentofu.org`; the `terraform` extension's mirror tag
    defaults to `registry.terraform.io`.""",
    attrs = {
        "name": attr.string(
            doc = "The name of the modules hub repo.",
            mandatory = True,
        ),
        "registry": attr.string(
            doc = """Registry hostname to query. Empty picks
            `registry.opentofu.org`.""",
            default = "",
        ),
        "root": attr.label(
            doc = """Any `.tf` file inside the root module directory. The
            extension reads every `*.tf` sibling of this file and
            enumerates `module { source = "…" }` blocks.""",
            mandatory = True,
            allow_single_file = [".tf"],
        ),
    },
)

opentofu = module_extension(
    doc = "Bzlmod extension for OpenTofu external modules.",
    implementation = _opentofu_impl,
    tag_classes = {
        "modules": _MODULES_TAG,
    },
)
