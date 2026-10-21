"""terraform_external_module"""

load(
    "//terraform/private:terraform.bzl",
    _terraform_external_module = "terraform_external_module",
)

terraform_external_module = _terraform_external_module
