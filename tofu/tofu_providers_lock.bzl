"""tofu_providers_lock"""

load(
    "//tofu/private:engine_rules.bzl",
    _tofu_providers_lock = "tofu_providers_lock",
)

tofu_providers_lock = _tofu_providers_lock
