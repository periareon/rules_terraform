"""terraform_provider"""

load(
    "//engine:terraform.bzl",
    _terraform_provider = "terraform_provider",
)

terraform_provider = _terraform_provider
