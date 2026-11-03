"""Engine-bound rules for `//tofu`: one factory invocation.

Aspects must be bound to top-level Starlark variables in the file where they
were first created, so each engine-bound aspect and rule from
`make_engine_rules(...)` gets a top-level `tofu_*` binding here. The public
`//tofu:tofu_*.bzl` files just re-export from these.
"""

load("//engine:engine_factory.bzl", "make_engine_rules")
load(":engine.bzl", "TOFU_ENGINE")

visibility(["//tofu/..."])

TOFU_RULES = make_engine_rules(engine = TOFU_ENGINE)

tofu_module = TOFU_RULES.module
tofu_binary = TOFU_RULES.binary
tofu_test = TOFU_RULES.test
tofu_plan_test = TOFU_RULES.plan_test
tofu_validate_aspect = TOFU_RULES.validate_aspect
tofu_validate_test = TOFU_RULES.validate_test
tofu_fmt_aspect = TOFU_RULES.fmt_aspect
tofu_fmt_test = TOFU_RULES.fmt_test
tofu_providers_lock = TOFU_RULES.providers_lock
tofu_formatter = TOFU_RULES.formatter
tofu_cli = TOFU_RULES.cli
current_tofu_toolchain = TOFU_RULES.current_toolchain
