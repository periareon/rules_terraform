run "with_default_name" {
  command = plan

  assert {
    condition     = output.resource_name == "unset"
    error_message = "default variable value did not flow through"
  }
}

run "with_override" {
  command = plan

  variables {
    name = "ci-value"
  }

  assert {
    condition     = output.resource_name == "ci-value"
    error_message = "override variable value did not flow through"
  }
}
