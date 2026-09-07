# rules_terraform

## Overview

This repository implements Bazel rules for
[Terraform](https://developer.hashicorp.com/terraform) and
[OpenTofu](https://opentofu.org/).

## Setup

Add rules_terraform to your `MODULE.bazel`:

```python
bazel_dep(name = "rules_terraform", version = "{version}")
```

Toolchains for both engines are auto-registered — no `use_extension` or
`register_toolchains` call is required. Pick a specific version by flipping
the corresponding string flag:

```
--@rules_terraform//terraform/settings:version=1.14.1
--@rules_terraform//opentofu/settings:version=1.10.6
```

Both default to the latest release shipped in
[`//terraform/private:versions.bzl`](../../terraform/private/versions.bzl) /
[`//opentofu/private:versions.bzl`](../../opentofu/private/versions.bzl).

To fetch external providers or registry modules, opt into the `terraform`
extension explicitly:

```python
terraform = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform")
terraform.providers(
    name = "my_providers",
    lock = "//path/to:.terraform.lock.hcl",
)
use_repo(terraform, "my_providers")
```

## Running the engine CLI directly (`@terraform` / `@opentofu`)

rules_terraform ships two hub repositories — `@terraform` and `@opentofu`
— that let a user invoke the toolchain-resolved engine binary from any
subdirectory of their workspace:

```bash
cd path/to/my/tf/module
bazel run @terraform -- plan             # ≈ terraform plan
bazel run @terraform -- init             # ≈ terraform init
bazel run @opentofu -- state list        # ≈ tofu state list
```

The wrapper `chdir`s to `$BUILD_WORKING_DIRECTORY` (the shell cwd where
`bazel run` was invoked) before exec-ing the engine, so relative paths
and any `terraform.tfstate` land in the directory you're standing in —
just like the native CLI. Version resolution follows the same
`//terraform/settings:version` / `//opentofu/settings:version` flags as
the rest of the ruleset, so you get one hermetic Terraform release
across all invocations.

**This is NOT the Bazel-managed workflow.** `@terraform` does no init
aspect, no lock-file rewriting, no `.terraform` construction —
`terraform init` still runs against your source tree, hits the network,
and writes state. Reach for it when you want a one-off CLI invocation
(state manipulation, ad-hoc plan against an unrelated module) without
wiring up a `terraform_binary` target for the module.

To use `@terraform` / `@opentofu` from downstream, add them to your
`MODULE.bazel`:

```python
terraform_toolchains = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform_toolchains")
use_repo(terraform_toolchains, "terraform")

opentofu_toolchains = use_extension("@rules_terraform//opentofu:extensions.bzl", "opentofu_toolchains")
use_repo(opentofu_toolchains, "opentofu")
```

The extensions themselves are already invoked by rules_terraform's own
`MODULE.bazel` (they register toolchains); the `use_repo` line only
binds the repo name in your namespace so `@terraform` / `@opentofu`
resolve.

## Bazel-managed Terraform

When a `terraform_module` is built through Bazel, an init aspect
assembles the whole **module directory** hermetically — the directory
the engine will run in, `.tf` files and `.terraform/` alike — rather
than letting `terraform init` build it. The result is a single Bazel
tree artifact that `terraform_binary` and the validate rules copy and
`cd` into. Every network fetch happens at repository-rule /
bzlmod-extension time; build actions are offline. As a consequence:

- **Provider binaries** are fetched at repository-rule time and copied
  into `.terraform/providers/…` during the aspect's action. The lock
  file's `h1:` hashes are rewritten to match the actually-installed
  binary layout.
- **External modules** (from a Terraform registry) are resolved via a
  Bazel-owned lock file, downloaded at repository-rule time, and copied
  into `.terraform/modules/…` with a generated `modules.json` manifest.
- **Local child modules** — other `terraform_module` targets in the
  monorepo — are placed at the relative `source` path the parent's
  `module` block names, so Terraform resolves them the way it resolves
  any local module. Packages nested under the parent land there
  automatically; anything else is matched to the `module` block whose
  `source` names it.

A `terraform_module` is exactly one directory: every file in `srcs`
must live directly in the target's own package. Nested `.tf` files are
a child module and belong in their own `terraform_module`. This is
enforced at analysis time, and it is what lets the aspect know which
directory it is building without guessing.

The full mechanics — how the extensions resolve each dependency type,
what each lock file looks like, and how to keep them fresh — are in
[External dependencies and lock files](#external-dependencies-and-lock-files)
below.

### Direct `terraform` CLI incompatibility

Once a `terraform_module` has Bazel-managed dependencies, running
`terraform` (or `tofu`) directly outside Bazel is **not expected to work**:
the module directory is Bazel's construction, `h1:` hashes are rewritten
for the installed platform binary, and `modules.json` reflects the Bazel
target graph — not the source tree.

Use `bazel run` to invoke the engine:

```bash
# Instead of: terraform plan
bazel run //path/to:terraform -- plan

# Instead of: terraform apply
bazel run //path/to:terraform -- apply
```

The `terraform_binary` rule creates an executable that copies the
aspect-built module directory into a writable temp dir and runs the
real `terraform` binary there.

For validation and formatting, use the corresponding test rules:

```python
terraform_validate_test(
    name = "validate_test",
    target = ":my_module",
)

terraform_fmt_test(
    name = "fmt_test",
    target = ":my_module",
)
```

## External dependencies and lock files

rules_terraform partitions external Terraform state into three buckets,
each with its own resolution path and (where applicable) lock file. Every
network fetch happens at repository-rule / bzlmod-extension time — build
actions never touch the network. What Terraform actually sees at run time
is a fully-populated module directory.

### At a glance

| Dependency type          | Fetched from                     | Lock file                       | Refresh via                                              |
|--------------------------|----------------------------------|---------------------------------|----------------------------------------------------------|
| Providers                | Terraform Registry v1 API        | `.terraform.lock.hcl`           | `bazel run //path:providers_lock` (a [`terraform_providers_lock`](./terraform/terraform_modules_lock.md) target) — see below |
| Registry modules         | Terraform Registry v1 API        | none — live-resolved by the `terraform.modules(...)` / `opentofu.modules(...)` extension | Automatic on `bazel fetch`. See "External registry modules" below for the tradeoff. |
| Local / in-repo modules  | Bazel target graph               | none                            | Edit `deps` on the parent `terraform_module` |

### Providers

```python
terraform = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform")
terraform.providers(
    name = "my_providers",
    lock = "//path/to:.terraform.lock.hcl",
    # Optional; default is `registry.terraform.io`. Use
    # `registry.opentofu.org` if you're fetching from the OpenTofu registry.
    # registry = "registry.opentofu.org",
)
use_repo(terraform, "my_providers")
```

The lock file is Terraform's native `.terraform.lock.hcl` — rules_terraform
consumes it, it doesn't author it.

**At repo-rule time** the extension:

1. Reads the lock file via `module_ctx.read`.
2. For every `(provider, platform)` pair, calls
   `https://<registry>/v1/providers/<namespace>/<name>/<version>/download/<os>/<arch>`
   via `module_ctx.download(...)` and reads the returned JSON to obtain
   the archive `download_url` + `shasum`.
3. Declares an `http_archive` per pair. These are lazy — Bazel only
   fetches the archive for the platform your build actually resolves.
4. Emits a hub repo `@my_providers` whose per-provider aliases pick the
   right platform archive via `select()`. Depend on
   `@my_providers//<namespace>_<name>` (e.g. `@my_providers//hashicorp_null`)
   from your `terraform_module.deps`.

**At build time** [`terraform_init_aspect`](./terraform/terraform_module.md)
extracts each provider's files into
`.terraform/providers/<registry>/<namespace>/<name>/<version>/<platform>/`
and recomputes the `h1:` hash in a copy of the lock file it writes inside
`.terraform/`. That rewrite is what lets `terraform init -get=false`
accept the Bazel-installed binaries.

**Regenerating.** Wire up a
[`terraform_providers_lock`](./terraform/terraform_modules_lock.md) target
(or [`opentofu_providers_lock`](./opentofu/opentofu_providers_lock.md) for
the OpenTofu variant):

```python
load(
    "@rules_terraform//terraform:terraform_modules_lock.bzl",
    "terraform_providers_lock",
)

terraform_providers_lock(
    name = "providers_lock",
    output = ".terraform.lock.hcl",
    target = ":my_module",
    # Optional; defaults to a 5-platform set (linux/darwin ×
    # amd64/arm64 + windows_amd64).
    # platforms = ["linux_amd64", "darwin_arm64"],
)
```

`bazel run //:providers_lock` seeds a temp directory with your `.tf`
sources, runs real `terraform providers lock -platform=<all>` under the
toolchain-fetched engine binary, and writes the multi-platform result
back into `$BUILD_WORKSPACE_DIRECTORY`. This is the only path that
produces hashes for platforms Bazel didn't resolve for the current
build — plain `terraform init` on your laptop locks the current
platform only.

**Drift check.** [`terraform_providers_lock_test`](./terraform/terraform_modules_lock.md)
fails if any provider declared in a `required_providers { … }` block
isn't in the lock file (or vice-versa). Pure text comparison — no
network. [`terraform_lock_diff_test`](./terraform/terraform_modules_lock.md)
goes further: it structurally compares the init-aspect-generated
`.terraform.lock.hcl` against a checked-in golden produced by real
`terraform init`, catching cases where the aspect's rewrite doesn't
match what the engine would produce.

### External registry modules

There is **no lock file** for registry modules — the extension resolves
them live against the Registry API on every fresh evaluation. Terraform
users load the extension from the terraform side:

```python
terraform = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform")
terraform.modules(
    name = "my_modules",
    root = "//path/to:main.tf",   # any .tf file in the root module directory
)
use_repo(terraform, "my_modules")
```

OpenTofu users load the parallel extension — same tag class shape, but
the registry defaults to `registry.opentofu.org`:

```python
opentofu = use_extension("@rules_terraform//opentofu:extensions.bzl", "opentofu")
opentofu.modules(
    name = "my_modules",
    root = "//path/to:main.tf",
)
use_repo(opentofu, "my_modules")
```

**At extension eval time** the impl reads every `*.tf` file in the same
directory as `root` (matching Terraform's own "root module is a
directory" model), parses `module { source = "…" }` blocks, and for
every registry-shaped source:

1. Hits `/v1/modules/<ns>/<name>/<provider>/versions` and picks the
   highest version satisfying the block's `version` constraint via a
   Starlark port of Terraform's semver logic.
2. Hits `/v1/modules/<ns>/<name>/<provider>/<version>` for metadata —
   reads `source` (git URL) and `tag`, constructs a direct GitHub
   tarball URL (`<source>/archive/refs/tags/<tag>.tar.gz`) with the
   matching `strip_prefix`.
3. Downloads the archive to compute the `sha256`.
4. Registers an `http_archive` per module.

Every downstream fetch goes direct to GitHub — no registry hop at build
time. Only GitHub-backed modules are supported; non-GitHub git hosts
fail with a clear error at eval time.

**At build time** the init aspect copies each module's files into
`.terraform/modules/<key>/` and adds a corresponding entry to
Terraform's `modules.json` manifest.

**Reproducibility and caching.** The extension is
`reproducible = False` and every `.tf` edit in the root module
directory invalidates it (bzlmod tracks each `module_ctx.read()`).
Re-eval cost is cached across runs via `module_ctx.facts` — but that
cache only persists when `MODULE.bazel.lock` is enabled. See
[Reproducibility](#reproducibility) for the full recipe and the
`Implementation detail: network calls per eval` note below.

**Non-default registries.** Pass `registry = "…"` on the tag class if
you're pointing at a private mirror or an alternate registry (e.g. a
Terraform user consuming the OpenTofu registry, or vice-versa).

<details>
<summary><strong>Implementation detail: network calls per eval</strong></summary>

For each `module { }` block, the extension issues up to three Registry
API requests, cached across evals via `module_ctx.facts`:

| Call                                              | Purpose                                                          | Cost                 | Skipped when                                                          |
|---------------------------------------------------|------------------------------------------------------------------|----------------------|-----------------------------------------------------------------------|
| `GET /v1/modules/<source>/versions`               | Resolve `version` constraint to a concrete SemVer                | Small JSON           | `version` is already an exact-pinned SemVer                            |
| `GET /v1/modules/<source>/<version>`              | Read `source` (git URL) + `tag` to build the archive URL         | Small JSON           | Facts cache has an entry for `<source>@<version>`                     |
| `GET <archive URL>`                               | Stream the archive body to compute an sha256 integrity           | **MB per module**    | Facts cache has an entry for `<source>@<version>`                     |

Facts is keyed by `<source>@<concrete_version>` and stores
`{url, strip_prefix, integrity}` — historical facts that don't change
once a module version is published. Only entries for currently-declared
modules carry across evals; entries for removed modules prune naturally.

</details>

### Local / in-repo modules

Modules living inside your monorepo don't need a lock file — Bazel's
own target graph is the source of truth.

Give the child its own `terraform_module` and list it in the parent's
`deps`. The path lives in one place — the `module` block — and `deps`
just says which target supplies it, the way a `py_library` dep supplies
an `import`:

```hcl
# root/main.tf
module "greeter" {
  source = "./modules/greeter"
}
```

```python
terraform_module(
    name = "root",
    srcs = glob(["*.tf"]),
    deps = ["//root/modules/greeter"],
)
```

When the child's package sits under the parent's — the usual case,
`//root/modules/greeter` beneath `//root` — the aspect places it at
`modules/greeter` inside the module directory, which is already what
`source = "./modules/greeter"` names.

When it doesn't, the source path is matched against the tail of each
dep's package. A child at `//shared/greeter` satisfies `source =
"./greeter"`; nothing changes in the BUILD file:

```python
terraform_module(
    name = "root",
    srcs = glob(["*.tf"]),
    deps = ["//shared/greeter"],
)
```

Two mistakes are build errors rather than a silently wrong module
directory: a local `source` no dep supplies, and a `terraform_module`
dep no `module` block references. If two deps could satisfy the same
source, that's an error too — rename one directory or nest it under the
parent's package.

### Update workflow — one-page summary

| Change                                | What to do                                                                                                    |
|---------------------------------------|---------------------------------------------------------------------------------------------------------------|
| Bump / add a provider                 | Update `required_providers { }`; regenerate `.terraform.lock.hcl` (real `terraform providers lock` or `bazel run //:providers_lock`) |
| Bump / add a registry module          | Edit the `module { source = "…" version = "…" }` block. Live-resolved on the next `bazel fetch`; regenerate `MODULE.bazel.lock` if you have it enabled. |
| Add / rename a local module           | Write the `module { source = "…" }` block and add the child to the parent's `deps`; no lock file involved |
| Verify everything                     | `bazel test //...` — runs validate, fmt, tftest, and every lock drift check in one shot                       |

## Reproducibility

The state of each bzlmod extension in rules_terraform:

| Extension                                          | Reproducible? | Why                                                                                                                                             |
|----------------------------------------------------|:-------------:|-------------------------------------------------------------------------------------------------------------------------------------------------|
| `terraform_toolchains` / `opentofu_toolchains`     | ✓             | Every URL + integrity is vendored in `//<engine>/private:versions.bzl`. No network at eval time; identical inputs → identical repo declarations. |
| `terraform.providers(...)`                         | ✓             | Reads a checked-in `.terraform.lock.hcl`; never resolves version constraints. Registry API is called to look up download URLs, but the version and hash come from the lock. |
| `terraform.modules(...)` / `opentofu.modules(...)` | ✗             | Live version-constraint resolution against the Registry API. `MODULE.bazel.lock` is the capture layer that closes the gap — see below.          |

### The role of `MODULE.bazel.lock`

The modules extension is the only piece of rules_terraform that
depends on `MODULE.bazel.lock` for both reproducibility AND performance.
`terraform_toolchains`, `opentofu_toolchains`, and
`terraform.providers(...)` all read fully vendored state and produce
deterministic output without any lockfile involvement. The modules
extension is different in two related ways:

1. **Reproducibility.** Without the lockfile, `~> 5.0` can resolve to
   `5.7.1` today and `5.7.2` tomorrow. With the lockfile enabled,
   bzlmod captures the extension's resolved output and reuses it on
   every subsequent eval — the extension is `reproducible = False`
   under Bazel's contract, but the lockfile makes builds
   byte-identical across time in practice.

2. **Performance.** Every `.tf` edit invalidates the extension (bzlmod
   tracks each `module_ctx.read()`). Without any cache, every re-eval
   hits the Registry API three times per module block, including
   downloading each archive to compute an sha256 — MB per module. The
   extension caches per-`(source, version)` archive URL + integrity in
   `module_ctx.facts`; those facts persist through
   `MODULE.bazel.lock`. Without the lockfile, facts is always empty,
   and every re-eval pays the full cost.

**Recommended downstream setup** — in your consuming repo's `.bazelrc`:

```
common --lockfile_mode=update
# or, once you're confident in the state:
common --lockfile_mode=strict
```

Commit `MODULE.bazel.lock`. This gives you:

- Deterministic builds regardless of version constraints in `.tf`.
- Cheap re-evals — cached facts short-circuit metadata calls and
  archive downloads on every re-run.
- A PR-visible diff (`MODULE.bazel.lock`) whenever a module version
  or archive hash actually changes.

**Bonus: pin exact versions in `module { }` blocks.** Combined with
`MODULE.bazel.lock`, exact pins let the extension skip even the
`/versions` API call — bringing warm-cache re-evals to zero network
calls per module:

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.7.1"   # not "~> 5.0"
}
```

### Rules_terraform's own `.bazelrc` does NOT enable the lockfile

The ruleset ships with `common --lockfile_mode=off`. This is
deliberate for a rules repo: bumping any dev-only `bazel_dep` version
would produce lockfile churn in unrelated PRs. Downstream users are
recommended to enable it in their own repos.

### Update workflow

To bump a module version with the lockfile enabled:

1. Edit the exact version (or constraint) in the `module { }` block.
2. Run `bazel mod deps --lockfile_mode=update` (or just
   `bazel fetch //...`) to regenerate `MODULE.bazel.lock`.
3. Commit both the `.tf` change AND the lockfile diff — reviewers see
   exactly which archive changed.

### Why not just mark the extension `reproducible = True`?

The extension makes live Registry API calls at eval time. Network
responses CAN vary across invocations (transient 5xx, mirror rotation,
registry outages, schema changes over years). Claiming
`reproducible = True` would be dishonest — same inputs, potentially
different outputs. `MODULE.bazel.lock` is Bazel's designed capture
layer for exactly this shape of extension, and setting
`reproducible = True` would tell bzlmod NOT to record the extension
in the lockfile — the opposite of what we want.

### When could `reproducible = True` come back?

- If HashiCorp publishes a Terraform-level module lockfile schema that
  captures resolved versions + hashes ahead of extension eval.
- If rules_terraform introduces a mode where the extension consumes a
  user-supplied pinned-version list without hitting the network at all
  (essentially reintroducing a lockfile — the one we deliberately
  removed in favor of live resolution + facts caching).

Neither is planned. Until then, `MODULE.bazel.lock` + exact pins covers
the same ground with Bazel's native machinery.
