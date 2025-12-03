"""Terraform bzlmod extensions.

Two extensions live here:

* `terraform_toolchains` — no user-facing configuration. On evaluation it
  materializes ONE hub repo (`@terraform_toolchains`) that declares a
  toolchain per (version, platform), each guarded by a `target_settings`
  matching `//terraform/settings:version_<v>`. rules_terraform's own
  `MODULE.bazel` `use_repo`s the hub and `register_toolchains`s it, so
  downstream users get toolchain resolution for free — no ceremony beyond
  flipping `//terraform/settings:version` to pick which Terraform release
  to actually download. Per-(version, platform) `http_archive`s are lazy;
  only the selected combination is fetched.
* `terraform` — carries `providers` and `modules` tag classes for users
  who want to pin providers/registry-modules via Bazel-managed fetching.
"""

load("//terraform/private:cli.bzl", "terraform_cli_hub")
load("//terraform/private:modules_extension.bzl", "resolve_all_modules")
load("//terraform/private:provider_repo.bzl", "DEFAULT_REGISTRY", "terraform_provider_hub", "terraform_providers_from_lock_file")
load(
    "//terraform/private:toolchain_repo.bzl",
    "PLATFORM_TO_CONSTRAINTS",
    "TERRAFORM_VERSIONS",
    "terraform_toolchain_repository",
    "terraform_toolchain_repository_hub",
)

_TERRAFORM_REGISTRY = "registry.terraform.io"

# Fixed hub name — since this extension takes no user config, we can bake
# it in. The corresponding `use_repo`/`register_toolchains` calls in
# rules_terraform's `MODULE.bazel` reference this exact name.
_HUB_NAME = "terraform_toolchains"

def _terraform_toolchains_impl(module_ctx):
    toolchain_names = []
    toolchain_labels = {}
    exec_compatible_with = {}
    target_settings = {}

    for version, platforms in TERRAFORM_VERSIONS.items():
        version_setting = "@rules_terraform//terraform/settings:version_" + version.replace(".", "_")
        for platform, info in platforms.items():
            if platform not in PLATFORM_TO_CONSTRAINTS:
                continue

            # Repo name includes both version and platform so declarations are
            # unique. Only the resolved (version, platform) actually fetches.
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
    )

    # `@terraform` — a one-target hub whose `bazel run @terraform -- <cmd>`
    # chdirs to $BUILD_WORKING_DIRECTORY and execs the resolved toolchain
    # `terraform` binary with the user's argv. Downstream users add
    # `use_repo(terraform_toolchains, "terraform")` to reference it.
    terraform_cli_hub(name = "terraform")

    # Reproducible: every URL + integrity hash is vendored in
    # //terraform/private:versions.bzl. No network at eval time; identical
    # inputs → identical repo declarations.
    return module_ctx.extension_metadata(reproducible = True)

terraform_toolchains = module_extension(
    doc = "Materializes the `@terraform_toolchains` hub covering every supported version.",
    implementation = _terraform_toolchains_impl,
)

def _terraform_impl(module_ctx):
    for mod in module_ctx.modules:
        for attrs in mod.tags.providers:
            provider_repos = terraform_providers_from_lock_file(
                module_ctx = module_ctx,
                lock_file_path = attrs.lock,
                hub_name = attrs.name,
                registry = attrs.registry,
            )

            provider_repos_str = {
                "{}:{}".format(source, platform): repo_name
                for (source, platform), repo_name in provider_repos.items()
            }

            terraform_provider_hub(
                name = attrs.name,
                provider_repos = provider_repos_str,
                lock_file_label = attrs.lock,
            )

    return resolve_all_modules(module_ctx, registry_default = _TERRAFORM_REGISTRY)

_PROVIDERS_TAG = tag_class(
    doc = "An extension for fetching external providers.",
    attrs = {
        "lock": attr.label(
            doc = "A lock file to use for fetching providers.",
            mandatory = True,
            allow_files = True,
        ),
        "name": attr.string(
            doc = "The name of the providers hub.",
            mandatory = True,
        ),
        "registry": attr.string(
            doc = "Registry hostname to query. Use `registry.opentofu.org` for OpenTofu.",
            default = DEFAULT_REGISTRY,
        ),
    },
)

_MODULES_TAG = tag_class(
    doc = """Live-resolves external Terraform registry modules from the
    `module { }` blocks in your root `.tf` files. Not reproducible across
    time when your blocks use version constraints (`~> 5.0`); pin exact
    versions for deterministic resolution.""",
    attrs = {
        "name": attr.string(
            doc = "The name of the modules hub repo.",
            mandatory = True,
        ),
        "registry": attr.string(
            doc = """Registry hostname to query. Empty (the default)
            picks `registry.terraform.io` when the extension is loaded
            from `//terraform:extensions.bzl`.""",
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

terraform = module_extension(
    doc = "Bzlmod extension for Terraform providers and external modules.",
    implementation = _terraform_impl,
    tag_classes = {
        "modules": _MODULES_TAG,
        "providers": _PROVIDERS_TAG,
    },
)
