"""terraform_providers_lock_test — drift check for `.terraform.lock.hcl`.

Fails if the lock file doesn't cover every provider named in the
`required_providers` blocks reachable from a module, or locks one nothing
names. Reads HCL text only; no engine binary is invoked.
"""

load(
    "//terraform/private:lock.bzl",
    _terraform_providers_lock_test = "terraform_providers_lock_test",
)

terraform_providers_lock_test = _terraform_providers_lock_test
