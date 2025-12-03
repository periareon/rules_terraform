"""terraform_provider_group"""

load(
    "//terraform/private:terraform.bzl",
    _terraform_provider_group = "terraform_provider_group",
)

terraform_provider_group = _terraform_provider_group
