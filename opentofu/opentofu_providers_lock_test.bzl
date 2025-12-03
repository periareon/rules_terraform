"""opentofu_providers_lock_test — alias for `terraform_providers_lock_test`.

The rule reads only HCL text (the `.terraform.lock.hcl` and the module's
`required_providers` blocks) and never invokes an engine binary, so the
same implementation covers both Terraform and OpenTofu.
"""

# buildifier: disable=bzl-visibility
load(
    "//terraform/private:lock.bzl",
    _terraform_providers_lock_test = "terraform_providers_lock_test",
)

opentofu_providers_lock_test = _terraform_providers_lock_test
