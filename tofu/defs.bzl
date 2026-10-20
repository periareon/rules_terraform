"""OpenTofu rules — parallel to `//terraform:defs.bzl` but bound to a
distinct toolchain type so both engines can coexist in one repo."""

load(
    ":tofu_binary.bzl",
    _tofu_binary = "tofu_binary",
)
load(
    ":tofu_external_module.bzl",
    _tofu_external_module = "tofu_external_module",
)
load(
    ":tofu_fmt_aspect.bzl",
    _tofu_fmt_aspect = "tofu_fmt_aspect",
)
load(
    ":tofu_fmt_test.bzl",
    _tofu_fmt_test = "tofu_fmt_test",
)
load(
    ":tofu_module.bzl",
    _tofu_module = "tofu_module",
)
load(
    ":tofu_plan_test.bzl",
    _tofu_plan_test = "tofu_plan_test",
)
load(
    ":tofu_provider.bzl",
    _tofu_provider = "tofu_provider",
)
load(
    ":tofu_providers_lock.bzl",
    _tofu_providers_lock = "tofu_providers_lock",
)
load(
    ":tofu_providers_lock_test.bzl",
    _tofu_providers_lock_test = "tofu_providers_lock_test",
)
load(
    ":tofu_test.bzl",
    _tofu_test = "tofu_test",
)
load(
    ":tofu_validate_aspect.bzl",
    _tofu_validate_aspect = "tofu_validate_aspect",
)
load(
    ":tofu_validate_test.bzl",
    _tofu_validate_test = "tofu_validate_test",
)

tofu_binary = _tofu_binary
tofu_external_module = _tofu_external_module
tofu_fmt_aspect = _tofu_fmt_aspect
tofu_fmt_test = _tofu_fmt_test
tofu_module = _tofu_module
tofu_plan_test = _tofu_plan_test
tofu_provider = _tofu_provider
tofu_providers_lock = _tofu_providers_lock
tofu_providers_lock_test = _tofu_providers_lock_test
tofu_test = _tofu_test
tofu_validate_aspect = _tofu_validate_aspect
tofu_validate_test = _tofu_validate_test
