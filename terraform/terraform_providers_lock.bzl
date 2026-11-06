"""terraform_providers_lock"""

load(
    "//terraform/private:engine_rules.bzl",
    _terraform_providers_lock = "terraform_providers_lock",
)

terraform_providers_lock = _terraform_providers_lock
