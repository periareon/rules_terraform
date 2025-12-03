terraform {
  required_version = ">= 1.0"

  required_providers {
    custom = {
      source  = "example/custom"
      version = "1.0.0"
    }
  }
}
