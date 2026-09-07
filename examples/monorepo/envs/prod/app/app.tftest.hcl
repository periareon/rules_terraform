# `terraform test` runs against the same built module tree, so it exercises the
# shared library through the exact `../../../` sources the environment declares.

run "allocates_one_subnet_per_requested_count" {
  command = plan

  assert {
    condition     = length(module.compute.subnet_cidrs) == 2
    error_message = "Shared network module did not allocate the default subnet count."
  }
}

run "carves_subnets_out_of_the_environment_cidr" {
  command = plan

  assert {
    condition     = module.compute.subnet_cidrs[0] == "10.20.0.0/24"
    error_message = "Subnets were not carved out of this environment's CIDR block."
  }
}

run "names_the_bucket_after_the_environment" {
  command = plan

  variables {
    environment = "staging"
  }

  assert {
    condition     = module.storage.bucket_name == "staging-app-assets"
    error_message = "Environment name did not flow through to the shared storage module."
  }
}
