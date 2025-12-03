"""terraform_module"""

load(
    "//terraform/private:terraform.bzl",
    _terraform_module = "terraform_module",
)

terraform_module = _terraform_module
