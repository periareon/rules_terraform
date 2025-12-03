"""Engine-bound rules for `//terraform` — one-line factory invocation.

Aspects must be bound to top-level Starlark variables in the file where they
were first created. Since `make_engine_rules` returns a struct of rules and
aspects, we expand each into a top-level `terraform_*` binding here so
Bazel accepts them.
"""

load(":engine_factory.bzl", "make_engine_rules")

visibility(["//terraform/..."])

TERRAFORM_RULES = make_engine_rules(
    engine = "terraform",
    toolchain_type = str(Label("//terraform:toolchain_type")),
)

terraform_binary = TERRAFORM_RULES.binary
terraform_test = TERRAFORM_RULES.test
terraform_validate_aspect = TERRAFORM_RULES.validate_aspect
terraform_validate_test = TERRAFORM_RULES.validate_test
terraform_fmt_aspect = TERRAFORM_RULES.fmt_aspect
terraform_fmt_test = TERRAFORM_RULES.fmt_test
terraform_providers_lock = TERRAFORM_RULES.providers_lock
