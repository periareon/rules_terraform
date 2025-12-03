"""Lock-file rules for `.terraform.lock.hcl`.

`terraform_providers_lock` regenerates the multi-platform lock file;
`terraform_providers_lock_test` catches drift against the module's
`required_providers` blocks; `terraform_lock_diff_test` structurally
diffs the init-aspect output against a checked-in golden.

External Terraform registry modules are resolved live by the
`terraform.modules(...)` bzlmod extension — no separate lock file, no
updater rule. See docs/src/index.md.
"""

load(
    "//terraform/private:engine_rules.bzl",
    _terraform_providers_lock = "terraform_providers_lock",
)
load(
    "//terraform/private:lock.bzl",
    _terraform_lock_diff_test = "terraform_lock_diff_test",
    _terraform_providers_lock_test = "terraform_providers_lock_test",
)

terraform_lock_diff_test = _terraform_lock_diff_test
terraform_providers_lock = _terraform_providers_lock
terraform_providers_lock_test = _terraform_providers_lock_test
