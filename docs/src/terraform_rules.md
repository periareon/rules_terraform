# Terraform Rules

## Public rules

- [terraform_binary](./terraform/terraform_binary.md) — `bazel run` wrapper for any `terraform` subcommand.
- [terraform_module](./terraform/terraform_module.md) — declares a `.tf` module with providers and deps.
- [terraform_provider](./terraform/terraform_provider.md) — declares a checked-in provider binary.
- [terraform_provider_group](./terraform/terraform_provider_group.md) — bundles providers with a shared lock file.
- [terraform_test](./terraform/terraform_test.md) — runs Terraform's HCL native test framework.
- [terraform_validate_test](./terraform/terraform_validate_test.md) / [aspect](./terraform/terraform_validate_aspect.md) — `terraform validate` as a Bazel test/aspect.
- [terraform_fmt_test](./terraform/terraform_fmt_test.md) / [aspect](./terraform/terraform_fmt_aspect.md) — `terraform fmt -check` as a Bazel test/aspect.
- [terraform_modules_lock and drift/diff tests](./terraform/terraform_modules_lock.md) — keep lock files in sync with sources.

## Module extensions

- [extensions](./terraform/extensions.md) — `terraform_toolchains`, `terraform`.
