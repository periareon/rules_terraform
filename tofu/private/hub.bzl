"""The rules the repositories `//tofu:extensions.bzl` generates load.

Toolchain repositories, the provider and module pools, the `deps` hubs and
the `@tofu` CLI hub are external repositories, so they cannot load `//engine`
directly: its files are visible to `//terraform` and `//tofu` only. They load
this file instead, which is why it is the one public `.bzl` under `private/`.
Not an API: nothing a BUILD file in a workspace should load.
"""

load(
    "//engine:terraform.bzl",
    _terraform_dependency_group = "terraform_dependency_group",
    _terraform_external_module = "terraform_external_module",
    _terraform_module_group = "terraform_module_group",
    _terraform_provider = "terraform_provider",
    _terraform_provider_group = "terraform_provider_group",
)
load("//engine:toolchain.bzl", _terraform_toolchain = "terraform_toolchain")
load(":engine_rules.bzl", _tofu_cli = "tofu_cli")

visibility("public")

terraform_dependency_group = _terraform_dependency_group
terraform_external_module = _terraform_external_module
terraform_module_group = _terraform_module_group
terraform_provider = _terraform_provider
terraform_provider_group = _terraform_provider_group
terraform_toolchain = _terraform_toolchain
tofu_cli = _tofu_cli
