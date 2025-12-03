"""terraform_fmt_test"""

load("//terraform/private:engine_rules.bzl", _terraform_fmt_test = "terraform_fmt_test")

terraform_fmt_test = _terraform_fmt_test
