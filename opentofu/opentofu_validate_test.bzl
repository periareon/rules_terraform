"""opentofu_validate_test"""

load(
    "//opentofu/private:engine_rules.bzl",
    _opentofu_validate_aspect = "opentofu_validate_aspect",
    _opentofu_validate_test = "opentofu_validate_test",
)

opentofu_validate_aspect = _opentofu_validate_aspect
opentofu_validate_test = _opentofu_validate_test
