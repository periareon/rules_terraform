"""terraform_provider"""

load(
    "//terraform/private:terraform.bzl",
    _terraform_provider = "terraform_provider",
)

terraform_provider = _terraform_provider
