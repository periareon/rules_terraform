"""Terraform rules"""

load(
    ":terraform_binary.bzl",
    _terraform_binary = "terraform_binary",
)
load(
    ":terraform_fmt_aspect.bzl",
    _terraform_fmt_aspect = "terraform_fmt_aspect",
)
load(
    ":terraform_fmt_test.bzl",
    _terraform_fmt_test = "terraform_fmt_test",
)
load(
    ":terraform_module.bzl",
    _terraform_module = "terraform_module",
)
load(
    ":terraform_modules_lock.bzl",
    _terraform_lock_diff_test = "terraform_lock_diff_test",
    _terraform_modules_lock = "terraform_modules_lock",
    _terraform_modules_lock_test = "terraform_modules_lock_test",
    _terraform_providers_lock_test = "terraform_providers_lock_test",
)
load(
    ":terraform_provider.bzl",
    _terraform_provider = "terraform_provider",
)
load(
    ":terraform_provider_group.bzl",
    _terraform_provider_group = "terraform_provider_group",
)
load(
    ":terraform_test.bzl",
    _terraform_test = "terraform_test",
)
load(
    ":terraform_validate_aspect.bzl",
    _terraform_validate_aspect = "terraform_validate_aspect",
)
load(
    ":terraform_validate_test.bzl",
    _terraform_validate_test = "terraform_validate_test",
)

terraform_binary = _terraform_binary
terraform_module = _terraform_module
terraform_lock_diff_test = _terraform_lock_diff_test
terraform_modules_lock = _terraform_modules_lock
terraform_modules_lock_test = _terraform_modules_lock_test
terraform_provider = _terraform_provider
terraform_provider_group = _terraform_provider_group
terraform_providers_lock_test = _terraform_providers_lock_test
terraform_test = _terraform_test
terraform_fmt_aspect = _terraform_fmt_aspect
terraform_fmt_test = _terraform_fmt_test
terraform_validate_aspect = _terraform_validate_aspect
terraform_validate_test = _terraform_validate_test
