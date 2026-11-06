# rules_terraform

Bazel rules for [Terraform](https://developer.hashicorp.com/terraform) and
[OpenTofu](https://tofu.org/). Every `terraform_*` rule has a `tofu_*`
twin that takes the same inputs and runs the other engine; the text below
says `terraform` and means both.

## Setup

```python
bazel_dep(name = "rules_terraform", version = "{version}")
```

Toolchains for both engines are registered by rules_terraform's own
`MODULE.bazel`. A build uses one release per engine: the root module's
`toolchain` tag, else the newest shipped in
[`//terraform/private:versions.bzl`](../../terraform/private/versions.bzl) /
[`//tofu/private:versions.bzl`](../../tofu/private/versions.bzl), which
carry the three newest releases with their checksums.

```python
terraform = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform")
terraform.toolchain(version = "1.9.8")

tofu = use_extension("@rules_terraform//tofu:extensions.bzl", "tofu")
tofu.toolchain(version = "1.9.1")
```

Any release works there. One outside the shipped table costs a single
fetch of its `SHA256SUMS`, recorded as a fact in `MODULE.bazel.lock`.
Changing the release is editing the tag; a tag in a dependency is ignored.

Nothing has to be installed on the host: the engine, provider archives
and modules are all fetched by Bazel, and every `bazel run` and
`bazel test` below uses the toolchain engine.

## Getting started

A root module new to Bazel is a directory of `.tf` files. Three things get
added around it: BUILD targets, a provider lock, and a `deps` tag in
`MODULE.bazel` that fetches what the lock and the `module` blocks name.
[Gazelle](./gazelle.md) writes the BUILD targets.

1. **Set up Gazelle** with the rules' language and run it:

   ```python
   # BUILD.bazel at the repository root
   load("@gazelle//:def.bzl", "gazelle", "gazelle_binary")

   gazelle_binary(
       name = "gazelle_bin",
       languages = ["@rules_terraform//terraform/gazelle"],
   )

   gazelle(
       name = "gazelle",
       gazelle = ":gazelle_bin",
   )
   ```

   `bazel run //:gazelle` writes a `terraform_module` per directory of
   configuration, `deps` between them following the local `module`
   blocks, and for a root (a directory with a `backend` or `cloud` block,
   or a `# gazelle:tf_kind root` directive) a `terraform_binary` named
   `terraform` and a `terraform_providers_lock` named
   `providers_lock.update`.

2. **Generate the lock** and commit it. This runs the toolchain engine's
   `providers lock` for every platform in the default set and writes
   `.terraform.lock.hcl` next to the sources; it needs the network.

   ```bash
   bazel run //path/to/app:providers_lock.update
   ```

   Rerun it whenever a `required_providers` block changes.

3. **Declare the `deps` tag** in `MODULE.bazel`. Gazelle names the hub a
   root depends on `@tf_<path>` with `/` and `-` replaced by `_`, or
   whatever a `# gazelle:tf_deps_hub` directive says; the tag must use
   that name.

   ```python
   terraform = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform")
   terraform.deps(
       name = "tf_path_to_app",
       lock = "//path/to/app:.terraform.lock.hcl",
       roots = ["//path/to/app:main.tf"],   # only if its `module` blocks name registry or git modules
   )
   use_repo(terraform, "tf_path_to_app")
   ```

4. **Run Gazelle again.** With the lock in place it adds the
   `terraform_providers_lock_test`, which fails when the lock drifts from
   the sources. Then:

   ```bash
   bazel test //path/to/app/...                      # validate, fmt, lock drift
   bazel run //path/to/app:terraform -- plan         # the engine, offline for providers and modules
   ```

Without Gazelle the same targets are written by hand; the
[monorepo example](https://github.com/periareon/rules_terraform/tree/main/examples/monorepo)
shows them for three environments sharing one lock. Add `.terraform/` to
`.gitignore`: the rules read nothing from it, and
[`init`](#initializing-in-place) writes it.

## Running the engine

### `terraform_binary`

```bash
bazel run //path/to:terraform -- plan
bazel run //path/to:terraform -- apply
```

The binary copies the module directory the build assembled, `.tf` files,
local child modules at their `source` paths, the lock and a populated
`.terraform/`, into a temp dir and runs the engine there with the
arguments given. The temp dir is removed when the command finishes.
Relative file arguments (`-out=tfplan`, `-var-file=x.tfvars`) resolve
against it, so pass absolute paths.

Because the build already installed the providers and the module
manifest, the only thing a run-time `init` still contributes is backend
setup, so the binary runs one only before subcommands that need a backend.
`version`, `fmt`, `validate`, `test` and `metadata` skip it and work
offline against a module with a remote backend.

**State.** A module with a `backend` or `cloud` block is unaffected: its
state belongs to the backend. A module with neither keeps state where the
native CLI keeps it, the working directory, which here is the temp dir,
so by default state goes with the run: `disposable_state` on the
`terraform_module` is `True`. A run that did write state is kept and its
path printed, so the record of an `apply` never vanishes silently, but
the next run starts fresh. Where state must outlive the run with no
backend (bootstrapping the bucket that will hold real state, a sandbox
kept for days), set `disposable_state = False`: the local backend is
pointed at a per-module directory under `bazel-out/rules_terraform/`,
which `bazel clean` deletes and which is named after every state-writing
command. Setting it on a module that declares a backend is an error.

**Environment.** `bazel run` keeps the operator's environment, which is
where credential helpers and `TF_WORKSPACE` live. The tests and the
validate aspect run the engine with the CLI configuration disabled
(`TF_CLI_CONFIG_FILE` pointed at an empty file, `CHECKPOINT_DISABLE=1`,
`TF_IN_AUTOMATION=1`), so a `~/.terraformrc` on one machine cannot change
what a check reports.

### Initializing in place

`bazel run //path/to:terraform -- init` is the one subcommand that does
not run in the temp dir, where its work would be deleted with it. It
installs what the build constructed into the module's source directory,
so the native CLI works there afterwards.

```bash
bazel run //envs/prod/app:terraform -- init
cd envs/prod/app
terraform plan            # native CLI, providers and modules from the build
```

The directory is the root module's package under the checkout, wherever
the command was run from; `BUILD_WORKSPACE_DIRECTORY` and the target
decide it, not the shell's cwd (that is the [`@terraform` hub's](#the-terraform-and-tofu-hubs)
job). The runner:

1. copies the built `.terraform/providers/` and `.terraform/modules/` over
   whatever is there, keeping `.terraform/environment` and the saved
   backend configuration, as a native re-`init` keeps them;
2. writes `.terraform.lock.hcl` next to the sources only when the module
   has none of its own (it depends on a shared hub), and says so;
3. adds the host platform's `h1:` hash to the lock for any installed
   provider the lock lacks it for, one line each, and says so. An unpacked
   package can only be verified by its `h1:`, so a lock made on another
   platform, or natively with fewer `-platform`s than the updater records,
   would make the engine refuse the package it is standing next to. It is
   the line `providers lock -platform=<host>` would add; commit it, or
   regenerate the lock for every platform with the updater;
4. runs the engine's `init -get=false -plugin-dir=.terraform/providers`
   in that directory with the remaining arguments appended, which is
   where the backend gets configured.

Each `init` flag is either the backend's business, which passes through,
or the build's, which is refused with the Bazel path named:

| Flag | Under the binary | Why |
|---|---|---|
| `-backend-config=…`, `-backend=false` | passes through | Backend configuration is the module's, not the build's. |
| `-reconfigure` | passes through | Re-reads the backend block, ignoring the saved configuration. The staged runs are implicitly always reconfigured, since a fresh copy has none saved; in place it matters. |
| `-migrate-state`, `-force-copy` | pass through | Moves state from the previously saved backend configuration to the current one. It needs that saved configuration, which only a persisted directory has, so this is the only place under Bazel it can work. |
| `-input`, `-lock`, `-lock-timeout`, `-no-color`, `-json` | pass through | Plain engine options. |
| `-lockfile=readonly` | passes through | Forbids every lock write, step 3 included: a lock without the host's hash is then an error naming the updater rather than an edit. |
| `-upgrade` | refused | Would re-resolve providers against the plugin dir and rewrite the lock. The versions are facts of the build: `bazel run //path/to:providers_lock.update` for providers, `RULES_TERRAFORM_UPGRADE=1 bazel fetch` for modules (see [Upgrading](#upgrading)). |
| `-get` | refused | The build installs the modules; the manifest is theirs. |
| `-plugin-dir` | refused | The build's providers are the plugin directory. |
| `-from-module` | refused | A root module is a `terraform_module` target. |
| `-chdir` (global) | refused | The target names the module directory. |
| `-help` | passes through | Answered by the engine, with nothing installed. |

`.terraform/` is the engine's cache and belongs in `.gitignore`; Gazelle
and the rules ignore it, and a Bazel run never reads it. This is the one
`bazel run` that writes into the source tree, and only because it was
asked to. The next `bazel run //path/to:terraform -- plan` still starts
from a fresh copy.

### Workspaces

The rules add no workspace concept of their own; they use Terraform's.
`TF_WORKSPACE` in the environment selects one for every project in a run:
`--action_env=TF_WORKSPACE=prod` for the validate aspect,
`--test_env=TF_WORKSPACE=prod` for the test rules, the shell for
`bazel run`. A root whose configuration is keyed on `terraform.workspace`
gets each of its workspaces checked by one test target per workspace,
with the `workspace` attribute of `terraform_validate_test`,
`terraform_test` or `terraform_plan_test` forcing it, and `no_validate`
on the module where the default workspace is not a valid one. A
`workspace select` inside a `bazel run` changes only the temp copy, so
it does not carry to the next run and the runner says so; `workspace new`
still creates the workspace in the backend.

### Tests and review artefacts

[`terraform_validate_test`](./terraform/terraform_validate_test.md) and
[`terraform_fmt_test`](./terraform/terraform_fmt_test.md) are `validate`
and `fmt -check` as Bazel tests. The same checks exist as aspects, which
the examples' `.bazelrc` attaches so `bazel build //...` runs them over
every module without a target per module; `no_validate` and `no_format`
tags opt a module out.

[`terraform_test`](./terraform/terraform_test.md) runs the engine's native
test framework. Each `run` block is reported as a JUnit test case through
`XML_OUTPUT_FILE`, so `bazel test` summaries show which run failed.
Terraform writes the report itself with `-junit-xml`; for OpenTofu the
runner builds it from the `-json-into` event stream and keeps that stream
too.

[`terraform_plan_test`](./terraform/terraform_plan_test.md) runs a real
`plan` and keeps `plan.tfplan`, `plan.json` and `plan.txt` as undeclared
outputs under `bazel-testlogs/<pkg>/<name>/test.outputs/`, so a plan can
be reviewed from CI artefacts. It passes when the plan succeeds, or with
`expect_no_changes` only when the plan is empty. A plan reaches the
backend and the provider APIs, so the target is tagged
`requires-network` and credentials go through `--test_env`; providers
that work offline (`null`, `local`, `random`) need neither. Plans hold
sensitive values, so treat the artefacts as you would the state.

[`terraform_providers_lock_test`](./terraform/terraform_providers_lock_test.md)
fails when `.terraform.lock.hcl` does not cover what the module tree
requires: every provider a `required_providers` block declares or a
`resource`, `data`, `ephemeral` or `provider` block implies, in the root
and in every installed module. No network, no engine.

### The `@terraform` and `@tofu` hubs

Two repositories let you invoke the toolchain engine in whatever
directory you are standing in, like the native CLI:

```bash
cd path/to/my/tf/module
bazel run @terraform -- providers lock
bazel run @tofu -- state list
```

The wrapper `chdir`s to `$BUILD_WORKING_DIRECTORY` before exec-ing the
engine. It does no init aspect and no `.terraform/` construction: a
`terraform init` there runs against the source tree and hits the network.
Reach for it for one-off CLI invocations against a directory with no
`terraform_binary`. Downstream, bind the names:

```python
terraform = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform")
use_repo(terraform, "terraform")
```

`bazel run @rules_terraform//terraform:format` (or `//tofu:format`)
rewrites the `.tf` files of every module in the workspace with the
toolchain engine's `fmt`; pass target patterns to narrow it.

## Dependencies

Every network fetch happens when the extension evaluates or a repository
is fetched; build actions are offline, and what the engine sees at run
time is a complete module directory. A `terraform_module` is one
directory: `srcs` are the files the engine loads (`.tf` and `.tf.json`,
plus `.tofu` and `.tofu.json` for `tofu_module`), all directly in the
target's package, and anything else is an analysis error rather than a
file the engine would silently skip. A nested directory of `.tf` files is
a child module with its own target.

| Dependency      | Fetched from                                                      | Pinned by                                                                 | Refresh                                                                 |
|-----------------|-------------------------------------------------------------------|---------------------------------------------------------------------------|-------------------------------------------------------------------------|
| Providers       | Registry v1 download API                                          | `.terraform.lock.hcl`                                                     | `bazel run //path:providers_lock.update`                                |
| Registry modules| Registry v1 API, archives from GitHub                             | the version each constraint resolved to, a fact in `MODULE.bazel.lock`    | edit the block, or `RULES_TERRAFORM_UPGRADE=1 bazel fetch //...`        |
| Git modules     | GitHub archives over https; the host's `git` for any other remote | the `?ref=`; what a tag or branch named is a fact in `MODULE.bazel.lock`  | edit the `?ref=`, or `RULES_TERRAFORM_UPGRADE=1 bazel fetch //...` for a branch |
| Local modules   | the Bazel target graph                                            | nothing                                                                   | edit `deps` on the parent                                               |

### The `deps` tag

One tag declares both halves of a root's external dependencies, because
that is how the engine treats them: `init` installs the providers the lock
pins and the modules the `module` blocks name in one step.

```python
terraform = use_extension("@rules_terraform//terraform:extensions.bzl", "terraform")
terraform.deps(
    name = "my_deps",
    lock = "//path/to:.terraform.lock.hcl",       # optional: providers
    roots = ["//path/to:main.tf"],                 # optional: registry and git modules named in that directory
    # registry = "registry.opentofu.org",          # default follows the extension
)
use_repo(terraform, "my_deps")
```

`@my_deps` carries every provider in the lock, the lock itself, and every
external module the roots name; a `terraform_module` that depends on it
needs no `lock` attribute, and a maintainer who adds a provider edits
`required_providers` and reruns the lock updater with no BUILD change.
`@my_deps//:providers`, `@my_deps//:modules` and
`@my_deps//<namespace>_<name>` are the parts. Archives are pooled across
hubs, so two locks that agree on a version fetch it once, and only the
platform a build resolves is fetched. The attributes are on the
[extension page](./terraform/extensions.md).

### Providers

The lock is Terraform's own `.terraform.lock.hcl`. The
[`terraform_providers_lock`](./terraform/terraform_providers_lock.md)
updater writes it by running the toolchain engine's
`providers lock -platform=<all>` over the sources, which is the one path
that records `h1:` hashes for every platform at once; the engine's own
`init` locks the platform it runs on only. The default set is
`linux_amd64`, `linux_arm64`, `darwin_amd64`, `darwin_arm64` and
`windows_amd64`.

The extension asks the registry only where each archive lives; the
archive's checksum must be one of the lock's `zh:` hashes, so the
registry cannot change what is installed. A platform is left out of a hub
only when the registry says the version was never published for it;
every other failed lookup fails the evaluation, so an outage cannot leave
a platform permanently missing from the lockfile. The build installs each
provider under `.terraform/providers/<registry>/<namespace>/<name>/<version>/<platform>/`
and rewrites the `h1:` hashes in the tree's copy of the lock to the
installed files, which is what lets the engine accept them.

### Providers built in the repo

A provider that is not on any registry is a
[`terraform_provider`](./terraform/terraform_provider.md) whose `files` is
the built binary, used like a hub-provided one:

```python
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
built in. The lock still needs an entry for the provider, written by hand
with the `version` and a placeholder `h1:`; the build replaces the hash
with that of the binary it installed. A module that depends on providers
but has no lock is an analysis error.

### Registry modules

A `module` block whose `source` is a registry address is resolved when the
extension evaluates: the highest version satisfying the block's constraint
is chosen once and recorded as a fact in `MODULE.bazel.lock`, and every
later evaluation declares it until an upgrade is asked for. List the
directory in a `deps` tag's `roots`; every `.tf` file in it is scanned,
and modules composed of other registry or git modules are followed.

```python
terraform.deps(
    name = "shared",
    lock = "//:.terraform.lock.hcl",
    roots = [
        "//envs/prod/app:main.tf",
        "//modules/naming:main.tf",     # a library whose blocks name a registry module
    ],
)
```

Archives come straight from GitHub, which is where the public registries
host their modules; a registry module hosted elsewhere is an error with
the address, and is supplied by hand as below. A source written with its
own hostname (`app.terraform.io/acme/vpc/aws`) is resolved against that
host. OpenTofu users use the `tofu` extension's `deps` tag, which defaults
to `registry.opentofu.org`.

### Git modules

A `module` block whose source is a git address goes through the same
`roots` scan with no registry involved, in the three spellings Terraform
accepts: `git::https://…` or `git::ssh://…`, the scp-like
`git@host:org/repo.git`, and the `github.com/org/repo` shorthand, each with
an optional `//subdir` and `?ref=`.

```hcl
module "vpc" {
  source = "git::ssh://git@git.example.com/acme/terraform-modules.git//vpc?ref=v1.4.0"
}
```

**What the ref pins.** A commit id is exact. A tag is looked up once and
what it names is recorded, so a moved tag is not followed. A branch, or no
`?ref=` meaning the default branch, is resolved to a commit the first time
and recorded the same way: a choice, like a version constraint, that only
`RULES_TERRAFORM_UPGRADE` moves. The native CLI follows such a source live
on every `init`, so a tag or commit in the block is what keeps the two
workflows on one revision.

**GitHub over `https`** needs no git: the extension fetches the archive
GitHub serves for the ref, records its integrity, and declares an
`http_archive` pinned by it. **Every other remote**, `ssh://` to GitHub
included, goes through the host's `git`: the ref is resolved with
`ls-remote`, checked out once to record the commit and read the module's
own references, and built as a `new_git_repository` of that commit,
fetched with the host's credentials. `git` has to be on `PATH` when the
extension evaluates and when the repository is fetched.

Not handled: `?sshkey=`, submodules, and non-git sources such as plain
`https://` archives or `s3::`.

### Modules the extension cannot fetch

Fetch the archive with any repository rule, declare a
[`terraform_external_module`](./terraform/terraform_external_module.md)
in its build file with `source` copied verbatim from the `module` block,
and put the target in `deps`; the build installs it under every block
whose `source` matches.

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
    source = "https://git.example.com/acme/terraform-vpc/-/archive/v1.4.0/terraform-vpc-v1.4.0.tar.gz",
    srcs = glob(["**/*.tf"]),
    visibility = ["//visibility:public"],
)
""",
)
```

### Local modules

A child module in the repository is its own `terraform_module`, listed in
the parent's `deps`; the path lives in the `module` block alone.

```hcl
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

A child whose package sits under the parent's lands at the path its
package implies. Any other child is matched to the `module` block whose
`source` names it by the tail of its package, so `//shared/greeter`
satisfies `source = "./greeter"`. A `source` no dep supplies, a dep no
block references, and two deps that could satisfy one source are build
errors.

## Reproducibility

The extensions are `reproducible = True`: given the same tags, files and
facts they declare the same repositories. Every answer taken from the
network is a fact in `MODULE.bazel.lock`: a tagged engine release's
checksums, where a provider archive lives, the version a module
constraint resolved to, the commit a git ref named, an archive's
integrity. A `.tf` edit under a `roots` directory re-evaluates the
extension, but with warm facts that makes no network calls.

Facts persist only while the lockfile is enabled, so downstream:

```
common --lockfile_mode=update
# or, once confident:
common --lockfile_mode=strict
```

and commit `MODULE.bazel.lock`. That gives deterministic module versions
however loosely the constraints are written, and a PR-visible diff
whenever a resolution changes. `--lockfile_mode=off` resolves live on
every evaluation, exactly as `terraform init` does. An exact pin in a
`module` block is still worth writing: it is the only form the native
`init` also treats as fixed.

### Upgrading

A recorded resolution is kept on purpose. To move a constraint or a branch
to what it resolves to today:

```bash
RULES_TERRAFORM_UPGRADE=1 bazel fetch //...   # or --repo_env=RULES_TERRAFORM_UPGRADE=1
```

Every constraint and git ref is resolved again and the facts rewritten;
facts that are properties of a published version, such as an archive's
integrity, are kept. Review the `MODULE.bazel.lock` diff and commit it.
Editing a block's `source`, `version` or `?ref=` is itself a new key, so a
changed block resolves on the next `bazel fetch` without the switch.
