# OpenTofu example

A minimal OpenTofu module wrapped in Bazel via rules_terraform. Structural
mirror of `examples/terraform`, but the workflow rules bind to the
OpenTofu toolchain, so `bazel run //:tofu` invokes the `tofu` binary.

## Layout

```
examples/opentofu/
├── MODULE.bazel          # resolves rules_terraform via local_path_override
├── BUILD.bazel           # opentofu_module + workflow rules for the root
├── main.tf               # root module (declares provider + uses ./modules/greeter)
├── variables.tf
├── outputs.tf
├── greeter.tftest.hcl    # HCL-native test (`tofu test`)
├── .terraform.lock.hcl   # provider lock file (checked in)
└── modules/greeter/
    ├── BUILD.bazel       # opentofu_module for the sub-module
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

- **Rule aliases.** `opentofu_module`, `opentofu_provider`, and
  `opentofu_provider_group` are the same rules as their `terraform_*`
  counterparts — file inputs are identical for both engines.
- **Workflow rules bind to a different toolchain.** `opentofu_binary`,
  `opentofu_test`, `opentofu_validate_test`, and `opentofu_fmt_test`
  require `//opentofu:toolchain_type`. Bazel resolves the `tofu` binary
  fetched by the `opentofu_toolchains` extension.
- **Version flag is `//opentofu/settings:version`.** Independent of
  Terraform's version flag, so a monorepo can pin different versions per
  engine.
- **Providers extension is shared.** rules_terraform ships a single
  `terraform` bzlmod extension for provider/module fetching. Its outputs
  are engine-neutral (the same on-disk layout works for both), so this
  example uses `use_extension("@rules_terraform//terraform:extensions.bzl", "terraform")`
  and OpenTofu consumes the fetched repos directly.
- **OpenTofu registry.** Set `registry = "registry.opentofu.org"` on
  `terraform.providers(...)` to fetch from the OpenTofu registry
  instead. The lock file's provider hostname prefix must match
  (regenerate with `tofu providers lock` if you switch).

## Pinning the OpenTofu version

```
bazel build //... --@rules_terraform//opentofu/settings:version=1.10.6
```

or in `.bazelrc`:

```
build --@rules_terraform//opentofu/settings:version=1.10.6
```

Defaults to the newest release baked into
`@rules_terraform//opentofu/private:versions.bzl`.

## Consuming rules_terraform from a real project

Drop the `local_path_override` block from [`MODULE.bazel`](MODULE.bazel)
and pin a released version from the Bazel Central Registry:

```python
bazel_dep(name = "rules_terraform", version = "x.y.z")
```
