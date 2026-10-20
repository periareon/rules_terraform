# Terraform Rules

## Public rules

- [terraform_binary](./terraform/terraform_binary.md) — `bazel run` wrapper for any `terraform` subcommand.
- [terraform_module](./terraform/terraform_module.md) — declares a `.tf` module with providers and deps.
- [terraform_external_module](./terraform/terraform_external_module.md) — supplies a module fetched from outside the workspace (git, private hosts) to `deps`.
- [terraform_provider](./terraform/terraform_provider.md) — declares a provider built in the repo. Registry providers come from a `deps` tag's hub instead.
- [terraform_test](./terraform/terraform_test.md) — runs Terraform's HCL native test framework, reporting each `run` block as a JUnit test case.
- [terraform_plan_test](./terraform/terraform_plan_test.md) — runs a real `plan` and keeps it as a reviewable test output; needs network.
- [terraform_validate_test](./terraform/terraform_validate_test.md) / [aspect](./terraform/terraform_validate_aspect.md) — `terraform validate` as a Bazel test/aspect.
- [terraform_fmt_test](./terraform/terraform_fmt_test.md) / [aspect](./terraform/terraform_fmt_aspect.md) — `terraform fmt -check` as a Bazel test/aspect.
- [terraform_providers_lock](./terraform/terraform_providers_lock.md) — `bazel run` updater that writes `.terraform.lock.hcl` with the toolchain engine; nothing needs installing on the host.
- [terraform_providers_lock_test](./terraform/terraform_providers_lock_test.md) — fails when the lock file and the `required_providers` blocks disagree.

## Module extensions

- [extensions](./terraform/extensions.md) — `terraform_toolchains`, `terraform`.
