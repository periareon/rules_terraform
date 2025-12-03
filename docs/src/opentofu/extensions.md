# OpenTofu Extensions

One module extension lives in `//opentofu:extensions.bzl`:

## `opentofu_toolchains`

No user-facing configuration. Mirrors `//terraform:extensions.bzl%terraform_toolchains`
but resolves against `//opentofu:toolchain_type`. Materializes
`@tofu_toolchains` covering every supported OpenTofu version, each
toolchain guarded by a `target_settings` on
[`//opentofu/settings:version_<v>`](./settings.md). rules_terraform's own
`MODULE.bazel` registers the hub so downstream users get toolchain
resolution for free.

```python
# In your MODULE.bazel — nothing to do beyond `bazel_dep`:
bazel_dep(name = "rules_terraform", version = "...")
```

## Providers and modules

Provider and external-module fetching is engine-neutral — use
`//terraform:extensions.bzl%terraform` for both engines. If you're
targeting OpenTofu, pass `registry = "registry.opentofu.org"` to
`terraform.providers` (or leave it defaulted to
`registry.terraform.io`, which OpenTofu also serves).
