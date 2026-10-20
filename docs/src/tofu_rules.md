# OpenTofu Rules

Everything under `//tofu` mirrors `//terraform` but binds to
`//tofu:toolchain_type`. Rule bodies are identical — only the
resolved toolchain differs — so behavior stays in lockstep between the
two engines. Data-only rules (`tofu_module`, `tofu_external_module`,
`tofu_provider`, `tofu_provider_group`) are literal aliases for their `terraform_*`
counterparts, provided so an OpenTofu-only project never has to import
a `terraform_*` symbol.

## Public rules

- [tofu_binary](./tofu/tofu_binary.md) — `bazel run` wrapper for any `tofu` subcommand.
- [tofu_module](./tofu/tofu_module.md) — alias for `terraform_module`.
- [tofu_external_module](./tofu/tofu_external_module.md) — alias for `terraform_external_module`.
- [tofu_provider](./tofu/tofu_provider.md) — alias for `terraform_provider`.
- [tofu_test](./tofu/tofu_test.md) — runs OpenTofu's HCL native test framework, reporting each `run` block as a JUnit test case.
- [tofu_plan_test](./tofu/tofu_plan_test.md) — runs a real `plan` and keeps it as a reviewable test output; needs network.
- [tofu_validate_test](./tofu/tofu_validate_test.md) — `tofu validate` as a Bazel test.
- [tofu_fmt_test](./tofu/tofu_fmt_test.md) — `tofu fmt -check` as a Bazel test.
- [tofu_providers_lock](./tofu/tofu_providers_lock.md) — `bazel run` updater that writes `.terraform.lock.hcl` with the toolchain `tofu`.
- [tofu_providers_lock_test](./tofu/tofu_providers_lock_test.md) — alias for the terraform drift test.

## Module extensions

- [extensions](./tofu/extensions.md) — `tofu_toolchains`.
