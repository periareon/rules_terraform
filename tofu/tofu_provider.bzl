"""tofu_provider — alias for `terraform_provider`.

Same rule under both names: a checked-in provider binary declaration is
engine-neutral, so `tofu_provider` is just a naming alias so
OpenTofu-only projects don't have to import a `terraform_*` symbol.
"""

# buildifier: disable=bzl-visibility
load(
    "//terraform/private:terraform.bzl",
    _terraform_provider = "terraform_provider",
)

tofu_provider = _terraform_provider
