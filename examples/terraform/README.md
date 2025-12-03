# Terraform example

A minimal Terraform module wrapped in Bazel via rules_terraform.

## Layout

```
examples/terraform/
├── MODULE.bazel          # resolves rules_terraform via local_path_override
├── BUILD.bazel           # terraform_module + workflow rules for the root
├── main.tf               # root module (declares provider + uses ./modules/greeter)
├── variables.tf
├── outputs.tf
├── greeter.tftest.hcl    # HCL-native test (`terraform test`)
├── .terraform.lock.hcl   # provider lock file (checked in)
└── modules/greeter/
    ├── BUILD.bazel       # terraform_module for the sub-module
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

## How the workflow rules map to native Terraform commands

| Bazel                                       | Native equivalent                |
|---------------------------------------------|----------------------------------|
| `bazel run  //:terraform -- plan`           | `terraform init && terraform plan` |
| `bazel run  //:terraform -- apply`          | `terraform init && terraform apply` |
| `bazel test //:validate`                    | `terraform init -backend=false && terraform validate` |
| `bazel test //:fmt`                         | `terraform fmt -check -recursive` |
| `bazel test //:tftest`                      | `terraform test` |
| `bazel test //:providers_lock`              | CI check that `.terraform.lock.hcl` covers every provider (no network) |
| `bazel test //...`                          | Run every check above in one shot |

`bazel run //:terraform` executes the real `terraform` binary inside a
hermetic tmpdir that has `.terraform/` pre-populated by the init aspect;
`terraform init` still runs but is short-circuited with `-get=false`,
so no network access is required.

## Why the wrapper matters

- **Hermetic providers.** Every provider named in `.terraform.lock.hcl`
  is fetched at repo-rule time by the `terraform` extension in
  [`MODULE.bazel`](MODULE.bazel) and installed into the aspect-built
  `.terraform/providers/` tree. `terraform init` never reaches the
  network at build time.
- **Cross-package modules.** The root module references the greeter via
  `source = "./modules/greeter"`; the `module_sources` attribute on
  `terraform_module` maps that source path to the Bazel target
  `//modules/greeter`, and the init tool copies its files into place
  under `.terraform/modules/`.
- **Reproducible lock files.** Lock file `h1:` hashes are recomputed
  against the platform-specific provider binaries Bazel installed, so
  Terraform accepts the pre-built `.terraform` tree at run time.
- **Same lock file works for OpenTofu.** See `examples/opentofu` — the
  same provider entries are reused via the `opentofu_*` rule aliases.

## Pinning the Terraform version

rules_terraform ships one toolchain per (Terraform version, platform),
each guarded by a `config_setting` on `//terraform/settings:version`.
Pick a specific release with either:

```
bazel build //... --@rules_terraform//terraform/settings:version=1.14.1
```

or a `.bazelrc` line:

```
build --@rules_terraform//terraform/settings:version=1.14.1
```

Defaults to the newest release baked into
`@rules_terraform//terraform/private:versions.bzl`.

## Consuming rules_terraform from a real project

Drop the `local_path_override` block from [`MODULE.bazel`](MODULE.bazel)
and pin a released version from the Bazel Central Registry:

```python
bazel_dep(name = "rules_terraform", version = "x.y.z")
```

Everything else stays the same.
