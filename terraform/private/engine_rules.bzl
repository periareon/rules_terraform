"""Engine-bound rules for `//terraform`: one factory invocation.

Aspects must be bound to top-level Starlark variables in the file where they
were first created, so each engine-bound aspect and rule from
`make_engine_rules(...)` gets a top-level `terraform_*` binding here. The public
`//terraform:terraform_*.bzl` files just re-export from these.
"""

load("//engine:engine_factory.bzl", "make_engine_rules")
load(":engine.bzl", "TERRAFORM_ENGINE")

visibility(["//terraform/..."])

TERRAFORM_RULES = make_engine_rules(engine = TERRAFORM_ENGINE)

terraform_module = TERRAFORM_RULES.module
terraform_binary = TERRAFORM_RULES.binary
terraform_test = TERRAFORM_RULES.test
terraform_plan_test = TERRAFORM_RULES.plan_test
terraform_validate_aspect = TERRAFORM_RULES.validate_aspect
terraform_validate_test = TERRAFORM_RULES.validate_test
terraform_fmt_aspect = TERRAFORM_RULES.fmt_aspect
terraform_fmt_test = TERRAFORM_RULES.fmt_test
terraform_providers_lock = TERRAFORM_RULES.providers_lock
terraform_formatter = TERRAFORM_RULES.formatter
terraform_cli = TERRAFORM_RULES.cli
current_terraform_toolchain = TERRAFORM_RULES.current_toolchain
