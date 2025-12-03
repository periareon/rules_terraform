"""OpenTofu rules — parallel to `//terraform:defs.bzl` but bound to a
distinct toolchain type so both engines can coexist in one repo."""

load(
    ":opentofu_binary.bzl",
    _opentofu_binary = "opentofu_binary",
)
load(
    ":opentofu_fmt_aspect.bzl",
    _opentofu_fmt_aspect = "opentofu_fmt_aspect",
)
load(
    ":opentofu_fmt_test.bzl",
    _opentofu_fmt_test = "opentofu_fmt_test",
)
load(
    ":opentofu_lock_diff_test.bzl",
    _opentofu_lock_diff_test = "opentofu_lock_diff_test",
)
load(
    ":opentofu_module.bzl",
    _opentofu_module = "opentofu_module",
)
load(
    ":opentofu_provider.bzl",
    _opentofu_provider = "opentofu_provider",
)
load(
    ":opentofu_provider_group.bzl",
    _opentofu_provider_group = "opentofu_provider_group",
)
load(
    ":opentofu_providers_lock.bzl",
    _opentofu_providers_lock = "opentofu_providers_lock",
)
load(
    ":opentofu_providers_lock_test.bzl",
    _opentofu_providers_lock_test = "opentofu_providers_lock_test",
)
load(
    ":opentofu_test.bzl",
    _opentofu_test = "opentofu_test",
)
load(
    ":opentofu_validate_aspect.bzl",
    _opentofu_validate_aspect = "opentofu_validate_aspect",
)
load(
    ":opentofu_validate_test.bzl",
    _opentofu_validate_test = "opentofu_validate_test",
)

opentofu_binary = _opentofu_binary
opentofu_fmt_aspect = _opentofu_fmt_aspect
opentofu_fmt_test = _opentofu_fmt_test
opentofu_lock_diff_test = _opentofu_lock_diff_test
opentofu_module = _opentofu_module
opentofu_provider = _opentofu_provider
opentofu_provider_group = _opentofu_provider_group
opentofu_providers_lock = _opentofu_providers_lock
opentofu_providers_lock_test = _opentofu_providers_lock_test
opentofu_test = _opentofu_test
opentofu_validate_aspect = _opentofu_validate_aspect
opentofu_validate_test = _opentofu_validate_test
