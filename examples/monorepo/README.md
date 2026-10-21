# Terraform monorepo example

A shared module library plus per-environment root modules — the layout most
Terraform monorepos converge on, and the one that needs `../` module sources to
work.

For the single-module getting-started path, see [`../terraform`](../terraform)
(and [`../tofu`](../tofu) for the same thing under OpenTofu).

## Layout

```
examples/monorepo/
├── MODULE.bazel              # two `deps` tags, one per lock file
├── BUILD.bazel               # exports the shared .terraform.lock.hcl
├── .terraform.lock.hcl       # provider lock shared by dev and prod
├── modules/                  # the shared library — owned by no environment
│   ├── network/              # leaf: pure computation, no provider
│   ├── compute/              # module "network" { source = "../network" }
│   ├── storage/
│   └── naming/               # module "label" { source = "cloudposse/label/null" }
└── envs/
    ├── dev/app/              # module "compute" { source = "../../../modules/compute" }
    ├── prod/app/             # same library, different variable defaults
    └── staging/app/          # extra provider, own .terraform.lock.hcl, names a
                              # registry module directly
```

The library cannot live under any one environment, because every environment
uses it. So the environments reach *up* out of their own directory to get at it,
and modules within the library reach *sideways* to each other. One library
module, `naming`, reaches *out* to the Terraform Registry.

## Commands

| Bazel                                              | Native equivalent                     |
|----------------------------------------------------|---------------------------------------|
| `bazel run  //envs/prod/app:terraform -- plan`      | `terraform init && terraform plan`    |
| `bazel run  //envs/prod/app:terraform -- apply`     | `terraform init && terraform apply`   |
| `bazel test //envs/prod/app:validate`               | `terraform init -backend=false && terraform validate` |
| `bazel test //envs/prod/app:fmt`                    | `terraform fmt -check -recursive`     |
| `bazel test //envs/prod/app:tftest`                 | `terraform test`                      |
| `bazel test //envs/staging/app:plan`                | `terraform plan`, kept as a test output |
| `bazel test //...`                                  | every check above, for every environment |

`bazel test //...` also runs `fmt` and `validate` over the shared library
itself, via the aspects wired up in [`.bazelrc`](.bazelrc) — no per-module test
target needed.

## What this example is showing

- **`../` module sources resolve.** The init aspect builds one tree artifact
  rooted at the deepest directory the root module and its module deps share —
  here, the repo root — and runs the engine in the environment's subdirectory
  within it. `../../../modules/compute` therefore lands *inside* the artifact.
  The relative geometry of your checkout is preserved, so paths in plan output
  and diagnostics are the paths you actually wrote.

- **`deps` are transitive.** `envs/prod/app` lists `//modules/compute` and
  `//modules/storage` — the two modules its own `module` blocks name, and
  nothing else. `compute`'s dependency on `network` travels with `compute`. Add
  a dependency to a library module and no environment has to be edited.

- **A missing dep is a build error, not a runtime surprise.** Every `module`
  block in the closure is matched to a dep. Drop `//modules/network` from
  `modules/compute` and the build fails naming the block, its directory and the
  unsatisfied source — rather than producing a tree the engine later rejects.

- **Shared modules are checked on their own.** `modules/compute` and
  `modules/storage` name the `null` provider, so they carry `lock` and the
  provider dep and can be validated standalone. A broken library module fails on
  its own target instead of in whichever environment adopts it next. A module
  that uses no provider — `modules/network` — needs neither.

- **One `deps` tag per lock file.** [`MODULE.bazel`](MODULE.bazel) declares
  `shared` for the lock dev and prod use, and `staging` for staging's own lock, since staging also uses the `random` provider. Each tag
  also lists the directories whose `module` blocks reach the registry:
  `modules/naming`, which wraps `cloudposse/label/null`, and `envs/staging/app`,
  which names the same module directly. A root module depends on its hub as
  a whole, so a Terraform maintainer who adds a provider or a registry module
  edits `.tf` files and reruns the lock updater without touching a BUILD
  file. The `naming` library depends on `@shared//:modules`, the registry-module
  half, so validating it installs no providers.

- **Everything is pooled.** Archives are shared across hubs by identity: the
  `null` provider both locks pin and the `label` module both tags name are
  each fetched and extracted once, and the module is installed under each
  `module` block that names it, keyed the way the engine addresses it
  (`naming.label` in the library, `tags` at staging's root). Each lock is
  regenerated with its own `providers_lock.update` target, using the toolchain
  engine; nothing is installed on the host.

- **A reviewable plan.** `bazel test //envs/staging/app:plan` runs a real
  `plan` and leaves `plan.txt`, `plan.json` and the binary plan under
  `bazel-testlogs/envs/staging/app/plan/test.outputs/`.

## Adding an environment

Create `envs/<env>/<app>/`, write the `.tf` files, and copy a BUILD file from an
existing environment. The only thing to keep in sync is that each `module` block
has a matching entry in `deps` — those two are the halves of one declaration.
If the environment needs a provider the shared lock does not cover, copy
`envs/staging/app` instead: give it its own lock, run its
`providers_lock.update` target, and add a `terraform.deps()` tag for the new
lock. If it names a registry module directly, add its directory to that tag's
`roots`.

## OpenTofu

The same layout works unchanged under the `tofu_*` rules; only the
toolchain differs. This example stays on Terraform to keep one lock file in
play — see [`../tofu`](../tofu) for the OpenTofu wiring, which pins
`registry = "registry.opentofu.org"` on the extension so the on-disk provider
layout matches what `tofu` looks for.

## Consuming rules_terraform from a real project

Drop the `local_path_override` block from [`MODULE.bazel`](MODULE.bazel) and pin
a released version from the Bazel Central Registry:

```python
bazel_dep(name = "rules_terraform", version = "x.y.z")
```

Everything else stays the same.
