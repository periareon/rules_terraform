"""opentofu_providers_lock — `bazel run` updater for `.terraform.lock.hcl`.

Runs real `tofu providers lock -platform=<all>` under the toolchain-fetched
`tofu` binary and writes the multi-platform lock file back to source. The
one path that produces hashes for platforms Bazel didn't resolve for the
current build.
"""

load(
    "//opentofu/private:engine_rules.bzl",
    _opentofu_providers_lock = "opentofu_providers_lock",
)

opentofu_providers_lock = _opentofu_providers_lock
