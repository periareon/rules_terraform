"""terraform_providers_lock_test — drift check for `.terraform.lock.hcl`.

Fails if the lock file doesn't cover every provider the module tree
requires, declared in `required_providers` or implied by the resources it
uses, local and installed external modules included, or locks one nothing
requires. Reads the directory the init aspect built; no engine binary is
invoked.
"""

load(
    "//engine:lock.bzl",
    _terraform_providers_lock_test = "terraform_providers_lock_test",
)

terraform_providers_lock_test = _terraform_providers_lock_test
