"""opentofu_provider_group — alias for `terraform_provider_group`.

Same rule under both names.
"""

# buildifier: disable=bzl-visibility
load(
    "//terraform/private:terraform.bzl",
    _terraform_provider_group = "terraform_provider_group",
)

opentofu_provider_group = _terraform_provider_group
