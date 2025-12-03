// Intentionally mis-formatted and referencing an undefined identifier so
// `terraform fmt -check` and `terraform validate` would both fail if the
// aspects didn't honor the `no_terraform_format` / `no_validate` tags on
// this module. HCL is still parseable, so `terraform_init_aspect` (which
// doesn't consult tags) still succeeds.

terraform{required_version=">= 1.0"}

variable"name"{type=string default="unset"}

output"broken"{value=nonexistent.attribute}
