# Terraform Extensions

One module extension lives in `//terraform:extensions.bzl`, `terraform`,
with two tag classes.

## `terraform.toolchain`

The extension always materializes one hub repo (`@terraform_toolchains`)
that declares a toolchain per platform for one Terraform release, and
`@terraform`, the CLI hub. rules_terraform's own `MODULE.bazel` `use_repo`s
the toolchain hub and `register_toolchains`s it, so downstream users get
toolchain resolution for free. Per-platform `http_archive`s are lazy; only
the resolved platform is fetched.

The release is the root module's `toolchain` tag, else the newest shipped
in `//terraform/private:versions.bzl` (the three newest when the table was
generated carry checksums). For any other release the extension fetches
its `SHA256SUMS` once and records the checksums as facts in
`MODULE.bazel.lock`.

```python
# Nothing to do beyond `bazel_dep` to use the newest shipped release.
bazel_dep(name = "rules_terraform", version = "...")

# To use another release:
terraform = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform")
terraform.toolchain(version = "1.9.8")
```

`terraform.toolchain`

| Attribute | Type | Description |
|---|---|---|
| `version` | `string` (required) | The release, e.g. `1.9.8`. |

Root module only, at most one tag; tags in dependencies are ignored. A
build has one engine release, and changing it is editing the tag.

## `terraform.deps`

The `deps` tag class: the providers a lock file pins and the
registry and git modules some directories' `module` blocks name, as one
hub per tag.

```python
terraform = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform")

# One `deps` tag per lock file. `lock` brings the providers the lock pins;
# `roots` brings the registry and git modules named by the `module` blocks
# in those directories (root modules and shared libraries alike). Either may
# be omitted.
terraform.deps(
    name = "app",
    lock = "//path/to/module:.terraform.lock.hcl",
    roots = [
        "//path/to/module:main.tf",
        "//path/to/library:main.tf",
    ],
    # registry = "registry.opentofu.org",  # optional; defaults to registry.terraform.io
)

use_repo(terraform, "app")
```

`@app` is a `terraform_dependency_group`: every provider in the lock, the
lock itself, and every external module the roots name. A `terraform_module`
that depends on it needs no `lock` attribute. `@app//:providers` and
`@app//:modules` are the two halves, and `@app//<namespace>_<name>` is one
provider. Name the hub after what it serves rather than after the tag.

Hubs are alias layers. The archives themselves go into pools shared by
every hub of the extension: one repository per distinct provider archive
(`rt_prov_<registry>_<namespace>_<name>_<version>_<platform>`) and one per
distinct module archive (`rt_mod_<registry>_<address>_<version>`), so two
hubs that agree on a version fetch and extract it once. Hub names share
one namespace across every Bazel module that uses the extension; a
duplicate is reported at evaluation time.

`terraform.deps`

| Attribute | Type | Description |
|---|---|---|
| `name` | `string` (required) | Hub repository name. |
| `lock` | `label` | A `.terraform.lock.hcl`. Every provider it pins is fetched for every platform the registry publishes. |
| `roots` | `label_list` | Directories whose `module { source = "…" }` blocks name registry or git modules (`git::…`, `git@…`, `github.com/…`, `?ref=` a tag, a full commit id or a branch; a branch, or no ref, resolves to a commit once and is kept as a fact), each as any `.tf` file inside it. Every `*.tf` in each directory is scanned; modules composed of other registry or git modules are followed. GitHub `https` remotes are fetched as integrity-pinned archives with no git involved; other remotes go through the host's `git`. |
| `root` | `label` | Shorthand for a one-element `roots`. |
| `registry` | `string` (default empty) | Registry host to query for lock entries and sources that name none. Empty means `registry.terraform.io` from this extension, `registry.opentofu.org` from the OpenTofu one. |
