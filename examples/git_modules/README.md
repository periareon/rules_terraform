# Git modules example

A root module whose `module` blocks name git repositories, wrapped in Bazel
via rules_terraform. No registry module is involved; the lock file covers
the providers the git modules themselves require.

## Layout

```
examples/git_modules/
├── MODULE.bazel          # resolves rules_terraform; one `deps` tag with the lock and this root
├── BUILD.bazel           # terraform_module + workflow rules for the root
├── main.tf               # three git-sourced module blocks
└── .terraform.lock.hcl   # provider lock file (checked in)
```

## What the three sources exercise

| Block        | Source                                                                 | Exercises                                                                                                   |
|--------------|------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| `user_data`  | `terraform-aws-eks.git//modules/_user_data?ref=v21.6.1`                 | A `//subdir` at a tag, whose templates live in `../../templates/`: the whole repository is installed and the module directory is the subdirectory within it. |
| `label_main` | `terraform-null-label.git?ref=main`                                    | A branch, resolved to a commit once and recorded as a fact.                                                 |
| `label`      | `terraform-null-label.git`                                             | No ref: the remote's default branch, treated the same way.                                                  |

Both repositories are on GitHub over `https`, so the extension fetches
archives and needs no `git`. Any other remote, `ssh://` included, is cloned
with the host's `git` and pinned by commit instead; the layout the engine
sees is the same.

## Commands

| Bazel                                        | Native equivalent              |
|----------------------------------------------|--------------------------------|
| `bazel test //:validate`                     | `terraform validate`           |
| `bazel test //:fmt`                          | `terraform fmt -check`         |
| `bazel test //:providers_lock`               | checks the lock matches the configuration |
| `bazel run //:providers_lock.update`         | `terraform providers lock`     |
| `bazel run //:terraform -- plan -input=false`| `terraform plan`               |
| `RULES_TERRAFORM_UPGRADE=1 bazel fetch //...`| `terraform init -upgrade` for the branch and the ref-less source |

This example runs with `--lockfile_mode=off`, like the others, so every
fresh evaluation resolves the branch and the default branch anew. A real
consumer keeps `MODULE.bazel.lock`, which is where the recorded commits
live between evaluations.
