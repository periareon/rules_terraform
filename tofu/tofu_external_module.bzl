"""tofu_external_module — alias for `terraform_external_module`.

Same rule under both names: a module fetched from outside the workspace is
engine-neutral, so `tofu_external_module` is just a naming alias so
OpenTofu-only projects don't have to import a `terraform_*` symbol.
"""

# buildifier: disable=bzl-visibility
load(
    "//terraform/private:terraform.bzl",
    _terraform_external_module = "terraform_external_module",
)

tofu_external_module = _terraform_external_module
