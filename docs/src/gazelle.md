# Gazelle

rules_terraform ships a [Gazelle](https://github.com/bazel-contrib/bazel-gazelle)
language per engine. It writes the BUILD files the rules need from the
configuration itself: one module target per directory of `.tf` files, with
`deps` kept in step with the `module` blocks, and the binary and lock targets
for a root.

## Setup

```python
# BUILD.bazel at the repository root
load("@gazelle//:def.bzl", "gazelle", "gazelle_binary")

gazelle_binary(
    name = "gazelle_bin",
    languages = [
        "@rules_terraform//terraform/gazelle",
        # "@rules_terraform//tofu/gazelle",  # for OpenTofu directories
    ],
)

gazelle(
    name = "gazelle",
    gazelle = ":gazelle_bin",
)
```

`bazel run //:gazelle` then writes or updates BUILD files; `bazel run
//:gazelle -- -mode diff` shows what it would change, which is what a CI
check runs.

## What a directory becomes

| The directory                                  | Generated                                                                                          |
|------------------------------------------------|----------------------------------------------------------------------------------------------------|
| has configuration files                        | `terraform_module(name = <directory name>, srcs = [...], data = [...], deps = [...])`              |
| also declares a `backend` or `cloud` block     | plus `terraform_binary(name = "terraform")` and `terraform_providers_lock(name = "providers_lock.update")` |
| also has a `.terraform.lock.hcl`               | plus `terraform_providers_lock_test(name = "providers_lock")`, and the updater if the directory is not a root |
| holds `.tofu` files                            | the `tofu_*` kinds instead                                                                         |

`srcs` are the files the engine loads, `.tf` and `.tf.json`, plus `.tofu`
and `.tofu.json` under OpenTofu. `data` is everything else a native run in
that directory could read: the remaining files, and the contents of
subdirectories that are not packages of their own. Build files, the lock,
state, and dotfiles are left out, as is anything under `.terraform/`.

`deps` has two parts. Every `module` block with a local source (`./…` or
`../…`) resolves to the module target in that directory; a directory nothing
generates a target for is reported. Then the dependency hubs: the ones a
`tf_deps_hub` directive names, or, for a root with a lock file and no
directive, `@tf_<path>` with `/` and `-` replaced by `_`.

Rules are merged, not overwritten: a hand-written `tags`, `visibility`, or
`disposable_state` stays, comments stay, and an attribute written as a `glob()`
is left alone with a warning, since a list cannot be merged into it. Delete
the glob to let Gazelle write the list.

## Directives

| Directive                                   | Meaning                                                                                                    |
|---------------------------------------------|------------------------------------------------------------------------------------------------------------|
| `# gazelle:tf_engine terraform\|tofu`        | Which engine's rules a directory tree gets. Unset, a directory with `.tofu` files is OpenTofu's, the rest Terraform's. |
| `# gazelle:tf_kind root\|module\|auto`       | Force a root (binary and lock targets) or a library. `auto`, the default, reads the configuration for a backend. |
| `# gazelle:tf_deps_hub NAME...`              | The hubs (`@NAME`) modules under the directory depend on. An empty value clears an inherited one.          |
| `# gazelle:tf_default_visibility LABEL...`   | Visibility written on new library modules under the directory. An existing rule keeps its own.              |

Directives inherit down the tree, so one `tf_deps_hub` on a module library's
parent directory covers every module in it, and one `tf_engine tofu` at the
repository root makes an OpenTofu-only repository.

## What it does not do

It does not write `.terraform.lock.hcl`; that is `providers_lock.update`.
It does not declare the `deps` tags in `MODULE.bazel`; the hub names it
writes are the names those tags must have. And it does not read expressions:
a `module` block whose `source` is not a literal is not resolved.
