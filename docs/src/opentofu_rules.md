# OpenTofu Rules

Everything under `//opentofu` mirrors `//terraform` but binds to
`//opentofu:toolchain_type`. Rule bodies are identical — only the
resolved toolchain differs — so behavior stays in lockstep between the
two engines. Data-only rules (`opentofu_module`, `opentofu_provider`,
`opentofu_provider_group`) are literal aliases for their `terraform_*`
counterparts, provided so an OpenTofu-only project never has to import
a `terraform_*` symbol.

## Public rules

- [opentofu_binary](./opentofu/opentofu_binary.md) — `bazel run` wrapper for any `tofu` subcommand.
- [opentofu_module](./opentofu/opentofu_module.md) — alias for `terraform_module`.
- [opentofu_provider](./opentofu/opentofu_provider.md) — alias for `terraform_provider`.
- [opentofu_provider_group](./opentofu/opentofu_provider_group.md) — alias for `terraform_provider_group`.
- [opentofu_test](./opentofu/opentofu_test.md) — runs OpenTofu's HCL native test framework.
- [opentofu_validate_test](./opentofu/opentofu_validate_test.md) — `tofu validate` as a Bazel test.
- [opentofu_fmt_test](./opentofu/opentofu_fmt_test.md) — `tofu fmt -check` as a Bazel test.

## Module extensions

- [extensions](./opentofu/extensions.md) — `opentofu_toolchains`.
