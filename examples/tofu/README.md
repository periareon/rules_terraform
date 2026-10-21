# OpenTofu example

A minimal OpenTofu module wrapped in Bazel via rules_terraform. Structural
mirror of `examples/terraform`, but the workflow rules bind to the
OpenTofu toolchain, so `bazel run //:tofu` invokes the `tofu` binary.

## Layout

```
examples/tofu/
├── MODULE.bazel          # resolves rules_terraform via local_path_override
├── BUILD.bazel           # tofu_module + workflow rules for the root
├── main.tf               # root module (declares provider + uses ./modules/greeter)
├── variables.tf
├── outputs.tf
├── greeter.tftest.hcl    # HCL-native test (`tofu test`)
├── .terraform.lock.hcl   # provider lock file (checked in)
└── modules/greeter/
    ├── BUILD.bazel       # tofu_module for the sub-module
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

## How the workflow rules map to native OpenTofu commands

| Bazel                                  | Native equivalent                 |
|----------------------------------------|-----------------------------------|
| `bazel run  //:tofu -- plan`           | `tofu init && tofu plan`          |
| `bazel run  //:tofu -- apply`          | `tofu init && tofu apply`         |
| `bazel test //:validate`               | `tofu init -backend=false && tofu validate` |
| `bazel test //:fmt`                    | `tofu fmt -check -recursive`      |
| `bazel test //:tftest`                 | `tofu test`                       |
| `bazel test //:providers_lock`         | CI check that `.terraform.lock.hcl` covers every provider (no network) |
| `bazel test //...`                     | Run every check above in one shot |

## Terraform vs OpenTofu — what's actually different

- **Rule aliases.** `tofu_module` and `tofu_provider` are the same rules
  as their `terraform_*` counterparts — file inputs are identical for both
  engines.
- **Workflow rules bind to a different toolchain.** `tofu_binary`,
  `tofu_test`, `tofu_validate_test`, and `tofu_fmt_test`
  require `//tofu:toolchain_type`. Bazel resolves the `tofu` binary
  fetched by the `tofu_toolchains` extension.
- **Version flag is `//tofu/settings:version`.** Independent of
  Terraform's version flag, so a monorepo can pin different versions per
  engine.
- **OpenTofu registry.** `tofu.deps(...)` defaults to
  `registry.opentofu.org`; it is the `terraform` extension's tag class with
  that default, so an OpenTofu repo never loads
  `//terraform:extensions.bzl`. The lock file has to come from the same registry — its
  hashes are what fetched archives are checked against — so regenerate
  it with `bazel run //:providers_lock.update` if you switch. That runs
  the toolchain `tofu`; nothing is needed on the host.

## Pinning the OpenTofu version

```
bazel build //... --@rules_terraform//tofu/settings:version=1.9.1
```

or in `.bazelrc`:

```
build --@rules_terraform//tofu/settings:version=1.9.1
```

Defaults to the newest release baked into
`@rules_terraform//tofu/private:versions.bzl`.

## Consuming rules_terraform from a real project

Drop the `local_path_override` block from [`MODULE.bazel`](MODULE.bazel)
and pin a released version from the Bazel Central Registry:

```python
bazel_dep(name = "rules_terraform", version = "x.y.z")
```
