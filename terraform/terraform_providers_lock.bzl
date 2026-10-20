"""terraform_providers_lock — `bazel run` updater for `.terraform.lock.hcl`.

Runs `terraform providers lock -platform=<all>` under the toolchain-fetched
`terraform` binary and writes the multi-platform lock file back to source.
No engine needs to be installed on the host. This is the one path that
produces hashes for platforms Bazel didn't resolve for the current build.
"""

load(
    "//terraform/private:engine_rules.bzl",
    _terraform_providers_lock = "terraform_providers_lock",
)

terraform_providers_lock = _terraform_providers_lock
