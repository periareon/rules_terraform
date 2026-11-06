"""terraform_providers_lock_test"""

load(
    "//engine:lock.bzl",
    _terraform_providers_lock_test = "terraform_providers_lock_test",
)

terraform_providers_lock_test = _terraform_providers_lock_test
