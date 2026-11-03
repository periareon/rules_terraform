"""terraform_external_module"""

load(
    "//engine:terraform.bzl",
    _terraform_external_module = "terraform_external_module",
)

terraform_external_module = _terraform_external_module
