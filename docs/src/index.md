# rules_terraform

## Overview

This repository implements Bazel rules for
[Terraform](https://developer.hashicorp.com/terraform) and
[OpenTofu](https://tofu.org/).

## Setup

Add rules_terraform to your `MODULE.bazel`:

```python
bazel_dep(name = "rules_terraform", version = "{version}")
```

Toolchains for both engines are auto-registered — no `use_extension` or
`register_toolchains` call is required. By default a build uses the newest
release shipped in
[`//terraform/private:versions.bzl`](../../terraform/private/versions.bzl) /
[`//tofu/private:versions.bzl`](../../tofu/private/versions.bzl); those
tables carry the three newest releases of each engine.

Any other release is one tag away. The extension fetches that release's
`SHA256SUMS` once and records the checksums as facts in
`MODULE.bazel.lock`, so pinning an older engine needs no change to
rules_terraform:

```python
terraform_toolchains = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform_toolchains")
terraform_toolchains.version(version = "1.9.8", default = True)   # default = True: use it unless the flag says otherwise

tofu_toolchains = use_extension("@rules_terraform//tofu:extensions.bzl", "tofu_toolchains")
tofu_toolchains.version(version = "1.9.1")                        # available, selected by flag
```

The flags select among the releases the hub knows, shipped or tagged:

```
--@rules_terraform//terraform/settings:version=1.9.8
--@rules_terraform//tofu/settings:version=1.9.1
```

Left empty they mean "the default": the root module's `default = True`
tag, else the newest shipped release.

Nothing has to be installed on the host: the engine binary, provider
archives and registry modules are all fetched by Bazel, and every
`bazel run` / `bazel test` below uses the toolchain-fetched engine.

## Getting started

A root module that is new to Bazel usually has `.tf` files and nothing
else. The provider lock file is the one artifact the rules need and the
source tree may not have yet, so the first steps produce it.

1. **Declare the module.** A `terraform_module` is one directory of
   `.tf` files. No lock, no deps yet:

   ```python
   load("@rules_terraform//terraform:defs.bzl", "terraform_module", "terraform_providers_lock")

   terraform_module(
       name = "app",
       srcs = glob(["*.tf"]),
   )

   # Writes .terraform.lock.hcl next to this BUILD file, for every platform
   # in the default set, using the toolchain's terraform. Needs network.
   terraform_providers_lock(
       name = "providers_lock.update",
       output = ".terraform.lock.hcl",
       target = ":app",
   )
   ```

2. **Generate the lock** and commit it:

   ```bash
   bazel run //path/to/app:providers_lock.update
   ```

   Rerun it whenever a `required_providers` block changes. There is no
   step that runs `terraform` from your `PATH`.

3. **Declare the module's dependencies** in `MODULE.bazel`, one `deps`
   tag per lock file:

   ```python
   terraform = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform")
   terraform.deps(
       name = "app_deps",
       lock = "//path/to/app:.terraform.lock.hcl",
       roots = ["//path/to/app:main.tf"],   # only if main.tf names registry modules
   )
   use_repo(terraform, "app_deps")
   ```

4. **Wire the module up** and add the workflow targets:

   ```python
   load("@rules_terraform//terraform:defs.bzl", "terraform_binary", "terraform_providers_lock_test", "terraform_validate_test")

   terraform_module(
       name = "app",
       srcs = glob(["*.tf"]),
       deps = ["@app_deps"],   # the providers, the lock, and the registry modules
   )

   terraform_binary(name = "terraform", root = ":app")       # bazel run //path/to/app:terraform -- plan
   terraform_validate_test(name = "validate", target = ":app")
   terraform_providers_lock_test(                            # fails when the lock drifts from the sources
       name = "providers_lock",
       lock = ".terraform.lock.hcl",
       target = ":app",
   )
   ```

5. **Add what the module calls.** A local child module is its own
   `terraform_module` listed in `deps`; a registry module comes through
   the directory being in a `deps` tag's `roots`, which the hub above
   already covers. Both are
   described under [External dependencies and lock files](#external-dependencies-and-lock-files).

A repo with several root modules repeats steps 1 to 4 per root, or
shares one lock file across roots as the [monorepo example](https://github.com/periareon/rules_terraform/tree/main/examples/monorepo)
does. Add `.terraform/` to `.gitignore`; the rules never write it into
the source tree, but a stray native `init` would.

To fetch providers and registry modules, declare a `deps` tag on the
`terraform` extension (or `tofu`, for OpenTofu): the lock file for
providers, the directories with `module` blocks for registry modules.

```python
terraform = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform")
terraform.deps(
    name = "app",
    lock = "//path/to:.terraform.lock.hcl",   # providers the lock pins
    roots = ["//path/to:main.tf"],             # registry modules named here
)
use_repo(terraform, "app")
```

## Running the engine CLI directly (`@terraform` / `@tofu`)

rules_terraform ships two hub repositories — `@terraform` and `@tofu`
— that let a user invoke the toolchain-resolved engine binary from any
subdirectory of their workspace:

```bash
cd path/to/my/tf/module
bazel run @terraform -- plan             # ≈ terraform plan
bazel run @terraform -- init             # ≈ terraform init
bazel run @tofu -- state list        # ≈ tofu state list
```

The wrapper `chdir`s to `$BUILD_WORKING_DIRECTORY` (the shell cwd where
`bazel run` was invoked) before exec-ing the engine, so relative paths
and any `terraform.tfstate` land in the directory you're standing in —
just like the native CLI. Version resolution follows the same
`//terraform/settings:version` / `//tofu/settings:version` flags as
the rest of the ruleset, so you get one hermetic Terraform release
across all invocations.

It is also how a Terraform maintainer manages dependencies without
touching Bazel: `bazel run @terraform -- init -upgrade` or
`bazel run @terraform -- providers lock` in a module directory writes
the lock the rules consume, and a module that depends on its providers
hub as a whole (`deps = ["@my_deps"]`) picks the change up with no
BUILD edit.

To reformat sources, `bazel run @rules_terraform//terraform:format`
(or `//tofu:format`) rewrites the `.tf` files of every module in the
workspace with the toolchain engine's `fmt`; pass target patterns to
narrow it. Modules tagged `no_format` or `no_terraform_format` are
skipped, matching the fmt aspect.

**This is NOT the Bazel-managed workflow.** `@terraform` does no init
aspect, no lock-file rewriting, no `.terraform` construction —
`terraform init` still runs against your source tree, hits the network,
and writes state. Reach for it when you want a one-off CLI invocation
(state manipulation, ad-hoc plan against an unrelated module) without
wiring up a `terraform_binary` target for the module.

To use `@terraform` / `@tofu` from downstream, add them to your
`MODULE.bazel`:

```python
terraform_toolchains = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform_toolchains")
use_repo(terraform_toolchains, "terraform")

tofu_toolchains = use_extension("@rules_terraform//tofu:extensions.bzl", "tofu_toolchains")
use_repo(tofu_toolchains, "tofu")
```

The extensions themselves are already invoked by rules_terraform's own
`MODULE.bazel` (they register toolchains); the `use_repo` line only
binds the repo name in your namespace so `@terraform` / `@tofu`
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

That temp dir is removed when the command finishes, which means **a
Bazel-run module needs a remote backend**. Without a `backend` or
`cloud` block, the runner refuses `apply`, `destroy`, `import`,
`refresh`, `taint`, `untaint` and the writing `state` subcommands, and
the message names the fix. `plan` and the read-only commands are never
refused.

Where disposable state is the point (demos, sandboxes, bootstrapping the
bucket that will hold real state), set `allow_ephemeral_state = True` on
the `terraform_module`. State is then kept between runs under
`bazel-out/<config>/bin/<pkg>/<name>.state/`: private to the machine,
forked per build configuration, and deleted by `bazel clean`. The runner
prints the path after each run. Relative file arguments (`-out=tfplan`,
`-var-file=x.tfvars`) resolve against the temp dir, so pass absolute
paths.

Because the aspect already installed the providers and the module
manifest, the only thing a run-time `terraform init` still contributes is
backend setup — so it runs only for subcommands that need one. `version`,
`fmt`, `validate`, `test` and `metadata` skip it and work offline against
a module with a remote backend; `plan`, `apply` and the rest initialize
the backend as before. The practical consequences: a `terraform_test` on
a module with a remote backend needs no credentials, and a configuration
error in one of those subcommands is reported as itself rather than as a
backend failure.

`terraform_validate_test`, the validate aspect and `terraform_test` run
the engine with the operator's CLI configuration disabled
(`TF_CLI_CONFIG_FILE` pointed at an empty file, `CHECKPOINT_DISABLE=1`,
`TF_IN_AUTOMATION=1`), so a `~/.terraformrc` on one machine cannot change
what a check reports. `bazel run` keeps the full environment, since that
is where credential helpers live.

### Tests and review artefacts

[`terraform_test`](./terraform/terraform_test.md) runs the engine's native
test framework. Each `run` block is reported as a JUnit test case
through `XML_OUTPUT_FILE`, so `bazel test` summaries and CI dashboards
show which run failed rather than one opaque target. Terraform writes
the report itself with `-junit-xml`; for OpenTofu, which has no such
flag, the runner builds it from the `-json-into` event stream and keeps
that stream too. The lock file and module manifest the test ran against
land in the undeclared outputs directory
(`bazel-testlogs/<pkg>/<name>/test.outputs/`).

[`terraform_plan_test`](./terraform/terraform_plan_test.md) runs a real
`plan` and keeps `plan.tfplan`, `plan.json` and `plan.txt` as
undeclared outputs, so a plan can be reviewed from CI artefacts. It
passes when the plan succeeds, or with `expect_no_changes` only when
the plan is empty. A plan reaches the backend and the provider APIs, so
the macro tags the target `requires-network`; credentials go through
`--test_env`. Providers that work offline (`null`, `local`, `random`)
need neither. Plans and state hold sensitive values, so treat those
artefacts as you would the state itself.

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
| Providers                | Terraform Registry v1 API        | `.terraform.lock.hcl`           | `bazel run //path:providers_lock.update` (a [`terraform_providers_lock`](./terraform/terraform_providers_lock.md) target) — see below |
| Registry modules         | Terraform Registry v1 API        | none — live-resolved from the `roots` of a `deps` tag | Automatic on `bazel fetch`. See "External registry modules" below for the tradeoff. |
| Local / in-repo modules  | Bazel target graph               | none                            | Edit `deps` on the parent `terraform_module` |

### The `deps` tag

Both halves of a root module's external dependencies are declared on one
tag, because that is how the engine treats them: `terraform init` installs
the providers the lock pins and the registry modules the `module` blocks
name in one step. The hub it produces, `@<name>`, is a
`terraform_dependency_group` carrying both, and a `terraform_module` that
depends on it needs no `lock` attribute.

```python
terraform = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform")
terraform.deps(
    name = "my_deps",
    lock = "//path/to:.terraform.lock.hcl",       # optional: providers
    roots = ["//path/to:main.tf"],                 # optional: registry modules
    # registry = "registry.opentofu.org",          # default follows the extension
)
use_repo(terraform, "my_deps")
```

Either half may be omitted: a shared library that names a registry module
but no provider gets a tag with `roots` only. The parts are addressable
too: `@my_deps//:providers`, `@my_deps//:modules`, and
`@my_deps//<namespace>_<name>` for one provider.

### Providers

The lock file is Terraform's native `.terraform.lock.hcl`. Write it with
the [`terraform_providers_lock`](./terraform/terraform_providers_lock.md)
updater (see [Getting started](#getting-started)); it runs the toolchain
engine, so no `terraform` install is involved.

**At repo-rule time** the extension:

1. Reads the lock file via `module_ctx.read`.
2. For every `(provider, platform)` pair, calls
   `https://<registry>/v1/providers/<namespace>/<name>/<version>/download/<os>/<arch>`
   via `module_ctx.download(...)` and reads the returned JSON to obtain
   the archive `download_url` + `shasum`. The `shasum` must be one of the
   lock entry's `zh:` hashes — those are the archive checksums recorded
   when the lock was written — so the registry can tell Bazel *where* the
   archive is but not *what* it should contain. A provider that resolves
   for none of the platforms is an error, not a silently thinner hub.
   Answers are cached in `module_ctx.facts`, so with `MODULE.bazel.lock`
   enabled a re-evaluation makes no provider requests at all.
3. Declares an `http_archive` per distinct archive, in a **pool shared by
   every `providers` hub**. The repository is named from the archive's
   identity (`rt_prov_<registry>_<namespace>_<name>_<version>_<platform>`),
   so two lock files that agree on a provider version fetch and extract it
   once. Archives are lazy — Bazel only fetches the platform your build
   actually resolves.
4. Emits the hub: `@my_deps` carries every provider in the lock plus the
   lock itself, and `@my_deps//<namespace>_<name>` is a per-provider alias
   that picks the right pool archive via `select()`. Depend on `@my_deps`
   and the module needs no `lock` attribute: a Terraform maintainer who
   adds a provider edits `required_providers` and regenerates the lock,
   and no BUILD file changes. Depend on individual aliases plus `lock` to
   install a subset.

**At build time** [`terraform_init_aspect`](./terraform/terraform_module.md)
extracts each provider's files into
`.terraform/providers/<registry>/<namespace>/<name>/<version>/<platform>/`
and recomputes the `h1:` hash in a copy of the lock file it writes inside
`.terraform/`. That rewrite is what lets `terraform init -get=false`
accept the Bazel-installed binaries.

**Regenerating.** Wire up a
[`terraform_providers_lock`](./terraform/terraform_providers_lock.md) target
(or [`tofu_providers_lock`](./tofu/tofu_providers_lock.md) for
the OpenTofu variant):

```python
load(
    "@rules_terraform//terraform:terraform_providers_lock.bzl",
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
sources, runs `terraform providers lock -platform=<all>` under the
toolchain-fetched engine binary, and writes the multi-platform result
back into `$BUILD_WORKSPACE_DIRECTORY`. This is the only path that
produces hashes for every platform at once — the engine's own `init`
locks the platform it runs on only.

**Drift check.** [`terraform_providers_lock_test`](./terraform/terraform_providers_lock_test.md)
fails if any provider declared in a `required_providers { … }` block
isn't in the lock file (or vice-versa). Pure text comparison — no
network. The lock's own hashes are enforced elsewhere: the extension
refuses an archive whose checksum is not among the lock's `zh:` entries,
and the engine verifies each installed provider directory against the
`h1:` the init aspect wrote.

### Providers built in the repo

A provider that is not on any registry — one you build from source in the
same workspace — is a [`terraform_provider`](./terraform/terraform_provider.md)
whose `files` is the built binary. It is used exactly like a hub-provided
provider:

```python
load("@rules_go//go:def.bzl", "go_binary")
load("@rules_terraform//terraform:defs.bzl", "terraform_module", "terraform_provider")

go_binary(
    name = "terraform-provider-custom",   # the engine requires this prefix
    srcs = ["main.go"],
)

terraform_provider(
    name = "custom",
    files = [":terraform-provider-custom"],
    source = "example/custom",             # matches `required_providers`
    version = "1.0.0",
)

terraform_module(
    name = "app",
    srcs = glob(["*.tf"]),
    lock = ".terraform.lock.hcl",
    deps = [":custom"],
)
```

Leave `platform` unset: it is read from the configuration the provider is
built in, so the same target works on a Linux CI runner and an Apple
Silicon laptop. The `.terraform.lock.hcl` still needs an entry for the
provider — write one by hand with the `version` and a placeholder `h1:`
hash; the init aspect replaces the `h1:` with the hash of the binary it
actually installed. A module that depends on providers but has no `lock`
is an analysis error, since the engine will not use a provider directory
it cannot check against one.

### External registry modules

There is **no lock file** for registry modules — the extension resolves
them live against the Registry API on every fresh evaluation. Terraform
users load the extension from the terraform side:

```python
terraform.deps(
    name = "shared",
    lock = "//:.terraform.lock.hcl",
    # Every directory whose `module` blocks name a registry module, root
    # modules and shared libraries alike, given as any .tf file inside it.
    roots = [
        "//envs/prod/app:main.tf",
        "//modules/naming:main.tf",
    ],
)
```

Then every `terraform_module` whose blocks name a registry module depends
on `@shared` (or `@shared//:modules` for a library that should not install
providers). Archives are pooled, and a module depending on the hub depends
on a candidate pool from which only what its own `module` blocks name is
installed, so a tag may list many directories. The
[monorepo example](https://github.com/periareon/rules_terraform/tree/main/examples/monorepo)
does this across three environments and a shared library.

OpenTofu users load the parallel extension — same tag class, but the
registry defaults to `registry.opentofu.org`:

```python
tofu = use_extension("@rules_terraform//tofu:extensions.bzl", "tofu")
tofu.deps(
    name = "app",
    lock = "//:.terraform.lock.hcl",
    roots = ["//:main.tf"],
)
use_repo(tofu, "app")
```

**At extension eval time** the impl reads every `*.tf` file in each
directory listed in `roots` (matching Terraform's own "root module is a
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
4. Once every `modules` tag has been resolved, registers one
   `http_archive` per distinct (registry, module address, version) in a
   **pool shared by every hub** (`rt_mod_<registry>_<address>_<version>`),
   extracted whole. Each `//subdir` any hub referenced is a target inside
   that one repository rather than a second download. The hub itself is a
   `terraform_module_group` over the pool targets it resolved to.

Every downstream fetch goes direct to GitHub — no registry hop at build
time. Only GitHub-backed modules are supported; non-GitHub git hosts
fail with a clear error at eval time. A source written with its own
hostname (`app.terraform.io/acme/vpc/aws`) is resolved against that
host rather than the tag's `registry`.

**Modules the extension cannot fetch** — a registry module hosted off
GitHub, or any plain `git::` / `https://` source — can still be
supplied by hand. Fetch the archive with whatever repository rule
fits, declare a [`terraform_external_module`](./terraform/terraform_external_module.md)
in its build file with `source` copied verbatim from the `module`
block, and put the target in `deps`:

```python
# MODULE.bazel
http_archive = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
http_archive(
    name = "acme_vpc",
    urls = ["https://git.example.com/acme/terraform-vpc/-/archive/v1.4.0/terraform-vpc-v1.4.0.tar.gz"],
    strip_prefix = "terraform-vpc-v1.4.0",
    integrity = "sha256-…",
    build_file_content = """
load("@rules_terraform//terraform:defs.bzl", "terraform_external_module")
terraform_external_module(
    name = "module",
    key = "acme_vpc",
    source = "git::https://git.example.com/acme/terraform-vpc.git?ref=v1.4.0",
    version = "1.4.0",
    srcs = glob(["**/*.tf"]),
    visibility = ["//visibility:public"],
)
""",
)
```

The init aspect installs it under every `module` block whose `source`
matches, the same way it places a registry module.

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

**Non-default registries.** Pass `registry = "…"` on the tag if you're
pointing at a private mirror or an alternate registry; it applies to the
providers and the modules of that tag alike.

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
| Bump / add a provider                 | Update `required_providers { }`; regenerate `.terraform.lock.hcl` with `bazel run` on the module's `terraform_providers_lock` target |
| Bump / add a registry module          | Edit the `module { source = "…" version = "…" }` block and make sure its directory is in a `deps` tag's `roots`. Live-resolved on the next `bazel fetch`; regenerate `MODULE.bazel.lock` if you have it enabled. |
| Add / rename a local module           | Write the `module { source = "…" }` block and add the child to the parent's `deps`; no lock file involved |
| Verify everything                     | `bazel test //...` — runs validate, fmt, tftest, and every lock drift check in one shot                       |

## Reproducibility

The state of each bzlmod extension in rules_terraform:

| Extension                                          | Reproducible? | Why                                                                                                                                             |
|----------------------------------------------------|:-------------:|-------------------------------------------------------------------------------------------------------------------------------------------------|
| `terraform_toolchains` / `tofu_toolchains`     | ✓             | Every URL + integrity is vendored in `//<engine>/private:versions.bzl`. No network at eval time; identical inputs → identical repo declarations. |
| `deps` tag, `lock` half                            | ✓             | Reads a checked-in `.terraform.lock.hcl`; never resolves version constraints. Registry API is called to look up download URLs, but the version and hash come from the lock. |
| `deps` tag, `roots` half                           | ✗             | Live version-constraint resolution against the Registry API. `MODULE.bazel.lock` is the capture layer that closes the gap — see below.          |

### The role of `MODULE.bazel.lock`

The modules extension is the only piece of rules_terraform that
depends on `MODULE.bazel.lock` for both reproducibility AND performance.
`terraform_toolchains`, `tofu_toolchains`, and the `lock` half of a
`deps` tag all read fully vendored state and produce
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

### Rules_terraform's own `MODULE.bazel.lock`

The ruleset commits its lockfile. Its own test fixtures use the modules
extension, so the lockfile is what keeps `bazel test //...` here offline
and repeatable, and a PR that bumps a fixture's module version shows the
resolved archive in the diff. The examples under `examples/` run with
`--lockfile_mode=off` on purpose: they stand in for a downstream user's
first build, where no facts exist yet.

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
