# Simple Terraform Test

A simple test case for `rules_terraform` demonstrating basic Terraform module creation without any providers.

## Overview

This test includes:
- A basic Terraform configuration with no providers
- Variable definitions for environment and project configuration
- A `terraform_module` rule to package the Terraform files
- A `terraform_binary` rule to create an executable wrapper

This test demonstrates that Terraform modules can be defined and built even without any external providers.

## Usage

### Build the Terraform module

```bash
bazel build //tests/simple:simple
```

### Run Terraform commands

To apply the configuration:

```bash
bazel run //tests/simple:terraform -- apply
```

To destroy the configuration:

```bash
bazel run //tests/simple:terraform -- destroy
```

## Files

- `main.tf`: Main Terraform configuration with only outputs
- `variables.tf`: Variable definitions
- `BUILD.bazel`: Bazel build configuration defining the rules
