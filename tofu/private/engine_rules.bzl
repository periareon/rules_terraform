"""Engine-bound rules for `//tofu` — one-line factory invocation.

Aspects must be bound to top-level Starlark variables in the file where they
were first created, so each engine-bound aspect and rule from
`make_engine_rules(...)` gets a top-level `tofu_*` binding here. The
public `//tofu:tofu_*.bzl` files just re-export from these.
"""

# buildifier: disable=bzl-visibility
load("//terraform/private:engine_factory.bzl", "make_engine_rules")

visibility(["//tofu/..."])

TOFU_RULES = make_engine_rules(
    engine = "tofu",
    toolchain_type = str(Label("//tofu:toolchain_type")),
)

tofu_binary = TOFU_RULES.binary
tofu_test = TOFU_RULES.test
tofu_plan_test = TOFU_RULES.plan_test
tofu_validate_aspect = TOFU_RULES.validate_aspect
tofu_validate_test = TOFU_RULES.validate_test
tofu_fmt_aspect = TOFU_RULES.fmt_aspect
tofu_fmt_test = TOFU_RULES.fmt_test
tofu_providers_lock = TOFU_RULES.providers_lock
