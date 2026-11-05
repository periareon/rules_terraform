# OpenTofu Extensions

One module extension lives in `//tofu:extensions.bzl`, `tofu`, with the
same two tag classes as the `terraform` extension.

## `tofu.toolchain`

The extension always materializes `@tofu_toolchains`, a hub declaring a
toolchain per platform for one OpenTofu release, the root module's
`toolchain` tag or else the newest shipped in `//tofu/private:versions.bzl`,
and `@tofu`, the CLI hub. rules_terraform's own `MODULE.bazel` registers the
hub so downstream users get toolchain resolution for free.

```python
# Nothing to do beyond `bazel_dep` to use the newest shipped release.
bazel_dep(name = "rules_terraform", version = "...")

# To use another release:
tofu = use_extension("@rules_terraform//tofu:extensions.bzl", "tofu")
tofu.toolchain(version = "1.9.1")
```

`tofu.toolchain` takes the same `version` attribute as the Terraform
extension's tag, with the same root-only rule; see
[the Terraform page](../terraform/extensions.md). For a tagged release the
extension fetches that release's `SHA256SUMS` once and records the
checksums as facts in `MODULE.bazel.lock`.

## `tofu.deps`

The same `deps` tag class as the `terraform` extension, defaulting to
`registry.opentofu.org`. An OpenTofu-only
repository uses it for everything and never loads
`//terraform:extensions.bzl`:

```python
tofu = use_extension("@rules_terraform//tofu:extensions.bzl", "tofu")
tofu.deps(
    name = "app",
    lock = "//path/to/module:.terraform.lock.hcl",   # written by tofu
    roots = ["//path/to/module:main.tf"],
)
use_repo(tofu, "app")
```

The attributes are those documented for the
[`terraform` extension](../terraform/extensions.md); only the default
`registry` differs. That default matters: `registry.opentofu.org` serves
OpenTofu's own builds of the `hashicorp/*` providers, whose archive hashes
differ from HashiCorp's, so a lock file written by `tofu` has to be
resolved against it. Write the lock with the module's
`tofu_providers_lock` updater and it will be.

Each extension pools its own archives. A repository using both engines
against the same dependencies should declare them through one extension
rather than both, or the same archive is fetched twice.
