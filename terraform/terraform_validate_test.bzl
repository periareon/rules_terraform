"""terraform_validate_test"""

load("//terraform/private:engine_rules.bzl", _terraform_validate_test = "terraform_validate_test")

terraform_validate_test = _terraform_validate_test
