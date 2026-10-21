"""Terraform providers.

`TerraformInfo` (and the other providers here) are shared with `//tofu`
so both engines operate on the same underlying `terraform_module` targets.
"""

visibility(["//terraform/...", "//tests/...", "//tofu/..."])

TerraformInfo = provider(
    # buildifier: disable=out-of-order-load
    doc = "Information about a Terraform module.",
    fields = {
        "allow_ephemeral_state": """bool: Whether `bazel run` may write local state for this
            module. See the attribute of the same name on `terraform_module`.""",
        "data": "depset[File]: All runfiles/data associated with the module.",
        "deps": "depset[TerraformInfo]: All direct dependencies of the module.",
        "external_modules": "depset[TerraformExternalModuleInfo]: External module dependencies.",
        "lock": "File: Optional .terraform.lock.hcl file.",
        "providers": """list[TerraformProviderInfo]: The providers this module depends on
            directly, from standalone `terraform_provider` deps and the
            `terraform_provider_group` dep, if any.""",
        "root_dir": """str: The module's directory, in module-staging terms (see
            `//terraform/private:util.bzl`'s `staged_path`). `terraform_module`
            validates that every src lives directly in it and that it is the
            target's own package, so consumers can run an engine there without
            inspecting the file list.""",
        "srcs": "depset[File]: All direct sources to the module.",
    },
)

TerraformProviderInfo = provider(
    doc = "Information about a Terraform provider.",
    fields = {
        "files": "depset[File]: Provider binary files.",
        "platform": "str: Platform string (e.g., 'linux_amd64', 'darwin_arm64').",
        "source": "str: Provider source (e.g., 'hashicorp/null').",
        "version": "str: Provider version.",
    },
)

TerraformProviderGroupInfo = provider(
    doc = "Information about a group of Terraform providers with their lock file.",
    fields = {
        "lock": "File: The .terraform.lock.hcl file for this group.",
        "providers": "list[TerraformProviderInfo]: List of providers in this group.",
    },
)

TerraformExternalModuleInfo = provider(
    doc = "Information about an external Terraform module downloaded from a registry.",
    fields = {
        "files": "depset[File]: All files in the downloaded module.",
        "source": """str: The `source` string as `module` blocks write it, subdir
            suffix included (e.g., 'terraform-aws-modules/eks/aws//modules/karpenter').""",
        "version": "str: Module version.",
    },
)

TerraformModuleGroupInfo = provider(
    doc = "Aggregated group of external Terraform modules from a module hub.",
    fields = {
        "modules": "list[TerraformExternalModuleInfo]: All external modules in the group.",
    },
)
