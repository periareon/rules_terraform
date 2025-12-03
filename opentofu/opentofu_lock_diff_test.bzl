"""opentofu_lock_diff_test — alias for `terraform_lock_diff_test`.

Diffs the init-aspect-generated `.terraform.lock.hcl` against a checked-in
golden produced by real `terraform init` or `tofu init`. Only reads the
two lock files — no engine binary invoked — so the same rule serves both.
"""

# buildifier: disable=bzl-visibility
load(
    "//terraform/private:lock.bzl",
    _terraform_lock_diff_test = "terraform_lock_diff_test",
)

opentofu_lock_diff_test = _terraform_lock_diff_test
