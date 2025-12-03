"""opentofu_fmt_test"""

load(
    "//opentofu/private:engine_rules.bzl",
    _opentofu_fmt_aspect = "opentofu_fmt_aspect",
    _opentofu_fmt_test = "opentofu_fmt_test",
)

opentofu_fmt_aspect = _opentofu_fmt_aspect
opentofu_fmt_test = _opentofu_fmt_test
