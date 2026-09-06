terraform {
  required_version = ">= 1.6"

  # The whole point of this fixture. Nothing listens on port 1, so any attempt
  # to initialize this backend fails immediately with a connection refused —
  # offline, with no credentials and without a DNS lookup. A target here that
  # passes is one that provably never touched the backend.
  #
  # `pg` rather than `s3` because it connects during `init` itself, and because
  # it needs no credential chain: an `s3` backend would either hang on instance
  # metadata or fail for a reason unrelated to what is under test.
  backend "pg" {
    conn_str = "postgres://terraform:terraform@127.0.0.1:1/terraform?sslmode=disable"
  }
}

variable "name" {
  type    = string
  default = "unset"
}

output "name" {
  value = var.name
}
