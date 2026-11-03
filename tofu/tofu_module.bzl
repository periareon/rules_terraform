"""tofu_module

The same rule body as `terraform_module`, bound to OpenTofu: `srcs` also
accepts `.tofu` and `.tofu.json`, which Terraform would ignore.
"""

load("//tofu/private:engine_rules.bzl", _tofu_module = "tofu_module")

tofu_module = _tofu_module
