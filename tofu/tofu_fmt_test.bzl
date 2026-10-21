"""tofu_fmt_test"""

load(
    "//tofu/private:engine_rules.bzl",
    _tofu_fmt_aspect = "tofu_fmt_aspect",
    _tofu_fmt_test = "tofu_fmt_test",
)

tofu_fmt_aspect = _tofu_fmt_aspect
tofu_fmt_test = _tofu_fmt_test
