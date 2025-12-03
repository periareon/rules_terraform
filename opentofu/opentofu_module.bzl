"""opentofu_module — alias for `terraform_module`.

Same rule under both names: a bundle of `.tf` files + `deps` + optional
lock is engine-neutral, so `opentofu_module` is just a naming alias so
OpenTofu-only projects don't have to import a `terraform_*` symbol.
"""

# buildifier: disable=bzl-visibility
load(
    "//terraform/private:terraform.bzl",
    _terraform_module = "terraform_module",
)

opentofu_module = _terraform_module
