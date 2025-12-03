"""Engine-bound rules for `//opentofu` — one-line factory invocation.

Aspects must be bound to top-level Starlark variables in the file where they
were first created, so each engine-bound aspect and rule from
`make_engine_rules(...)` gets a top-level `opentofu_*` binding here. The
public `//opentofu:opentofu_*.bzl` files just re-export from these.
"""

# buildifier: disable=bzl-visibility
load("//terraform/private:engine_factory.bzl", "make_engine_rules")

visibility(["//opentofu/..."])

OPENTOFU_RULES = make_engine_rules(
    engine = "opentofu",
    toolchain_type = str(Label("//opentofu:toolchain_type")),
)

opentofu_binary = OPENTOFU_RULES.binary
opentofu_test = OPENTOFU_RULES.test
opentofu_validate_aspect = OPENTOFU_RULES.validate_aspect
opentofu_validate_test = OPENTOFU_RULES.validate_test
opentofu_fmt_aspect = OPENTOFU_RULES.fmt_aspect
opentofu_fmt_test = OPENTOFU_RULES.fmt_test
opentofu_providers_lock = OPENTOFU_RULES.providers_lock
