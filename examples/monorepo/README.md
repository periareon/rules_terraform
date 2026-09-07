# Terraform monorepo example

A shared module library plus per-environment root modules — the layout most
Terraform monorepos converge on, and the one that needs `../` module sources to
work.

For the single-module getting-started path, see [`../terraform`](../terraform)
(and [`../opentofu`](../opentofu) for the same thing under OpenTofu).

## Layout

```
examples/monorepo/
├── MODULE.bazel              # one terraform.providers() call for the whole repo
├── BUILD.bazel               # exports the shared .terraform.lock.hcl
├── .terraform.lock.hcl       # provider lock, shared by every environment
├── modules/                  # the shared library — owned by no environment
│   ├── network/              # leaf: pure computation, no provider
│   ├── compute/              # module "network" { source = "../network" }
│   └── storage/
└── envs/
    ├── dev/app/              # module "compute" { source = "../../../modules/compute" }
    └── prod/app/             # same library, different variable defaults
```

The library cannot live under any one environment, because every environment
uses it. So the environments reach *up* out of their own directory to get at it,
and modules within the library reach *sideways* to each other.

## Commands

| Bazel                                              | Native equivalent                     |
|----------------------------------------------------|---------------------------------------|
| `bazel run  //envs/prod/app:terraform -- plan`      | `terraform init && terraform plan`    |
| `bazel run  //envs/prod/app:terraform -- apply`     | `terraform init && terraform apply`   |
| `bazel test //envs/prod/app:validate`               | `terraform init -backend=false && terraform validate` |
| `bazel test //envs/prod/app:fmt`                    | `terraform fmt -check -recursive`     |
| `bazel test //envs/prod/app:tftest`                 | `terraform test`                      |
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

- **One lock for the repo.** [`MODULE.bazel`](MODULE.bazel) makes a single
  `terraform.providers()` call against the root `.terraform.lock.hcl`, and every
  environment points its `lock` attribute at that same file. A repo that lets
  environments drift onto different provider versions would instead keep a lock
  beside each root module and make one call per lock.

## Adding an environment

Create `envs/<env>/<app>/`, write the `.tf` files, and copy a BUILD file from an
existing environment. The only thing to keep in sync is that each `module` block
has a matching entry in `deps` — those two are the halves of one declaration.

## OpenTofu

The same layout works unchanged under the `opentofu_*` rules; only the
toolchain differs. This example stays on Terraform to keep one lock file in
play — see [`../opentofu`](../opentofu) for the OpenTofu wiring, which pins
`registry = "registry.opentofu.org"` on the extension so the on-disk provider
layout matches what `tofu` looks for.

## Consuming rules_terraform from a real project

Drop the `local_path_override` block from [`MODULE.bazel`](MODULE.bazel) and pin
a released version from the Bazel Central Registry:

```python
bazel_dep(name = "rules_terraform", version = "x.y.z")
```

Everything else stays the same.
