"""tofu_validate_test"""

load(
    "//tofu/private:engine_rules.bzl",
    _tofu_validate_aspect = "tofu_validate_aspect",
    _tofu_validate_test = "tofu_validate_test",
)

tofu_validate_aspect = _tofu_validate_aspect
tofu_validate_test = _tofu_validate_test
