run "greets_world_by_default" {
  command = plan

  assert {
    condition     = module.greeter.message == "Hello, world!"
    error_message = "Default greeting did not render as expected."
  }
}

run "greets_named_user" {
  command = plan

  variables {
    name = "Alice"
  }

  assert {
    condition     = module.greeter.message == "Hello, Alice!"
    error_message = "Variable override did not flow through to the greeter."
  }
}
