"""Unit tests for the lock file parser"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//terraform/private:lock_hcl.bzl", "parse_lock_file")

def _parse_simple_provider_test_impl(ctx):
    env = unittest.begin(ctx)

    lock_content = """\
# This file is maintained automatically by "terraform init".
# Manual edits may be lost in future updates.

provider "registry.terraform.io/hashicorp/null" {
  version     = "3.2.4"
  constraints = "~> 3.0"
  hashes = [
    "h1:L5V05xwp/Gto1leRryuesxjMfgZwjb7oool4WS1UEFQ=",
    "zh:59f6b52ab4ff35739647f9509ee6d93d7c032985d9f8c6237d1f8a59471bbbe2",
  ]
}
"""

    providers = parse_lock_file(lock_content)

    asserts.equals(env, 1, len(providers), "Should parse one provider")

    provider = providers[0]
    asserts.equals(env, "hashicorp/null", provider.source, "Should parse provider source")
    asserts.equals(env, "3.2.4", provider.version, "Should parse version")
    asserts.equals(env, "~> 3.0", provider.constraints, "Should parse constraints")
    asserts.equals(env, 2, len(provider.hashes), "Should parse hashes")
    asserts.equals(env, "h1:L5V05xwp/Gto1leRryuesxjMfgZwjb7oool4WS1UEFQ=", provider.hashes[0], "Should parse first hash")

    return unittest.end(env)

parse_simple_provider_test = unittest.make(_parse_simple_provider_test_impl)

def _parse_multiple_providers_test_impl(ctx):
    env = unittest.begin(ctx)

    lock_content = """\
provider "registry.terraform.io/hashicorp/null" {
  version     = "3.2.4"
  constraints = "~> 3.0"
  hashes = [
    "h1:abc123",
  ]
}

provider "registry.terraform.io/hashicorp/random" {
  version     = "3.5.1"
  hashes = [
    "h1:def456",
    "zh:123456",
  ]
}
"""

    providers = parse_lock_file(lock_content)

    asserts.equals(env, 2, len(providers), "Should parse two providers")

    asserts.equals(env, "hashicorp/null", providers[0].source, "First provider source")
    asserts.equals(env, "3.2.4", providers[0].version, "First provider version")
    asserts.equals(env, "~> 3.0", providers[0].constraints, "First provider constraints")

    asserts.equals(env, "hashicorp/random", providers[1].source, "Second provider source")
    asserts.equals(env, "3.5.1", providers[1].version, "Second provider version")
    asserts.equals(env, "", providers[1].constraints, "Second provider should have no constraints")
    asserts.equals(env, 2, len(providers[1].hashes), "Second provider should have two hashes")

    return unittest.end(env)

parse_multiple_providers_test = unittest.make(_parse_multiple_providers_test_impl)

def _parse_empty_file_test_impl(ctx):
    env = unittest.begin(ctx)

    lock_content = """\
# This file is maintained automatically by "terraform init".
# Manual edits may be lost in future updates.
"""

    providers = parse_lock_file(lock_content)

    asserts.equals(env, 0, len(providers), "Should parse zero providers from empty file")

    return unittest.end(env)

parse_empty_file_test = unittest.make(_parse_empty_file_test_impl)

def _parse_provider_without_registry_prefix_test_impl(ctx):
    env = unittest.begin(ctx)

    lock_content = """\
provider "hashicorp/aws" {
  version = "5.0.0"
  hashes = [
    "h1:test123",
  ]
}
"""

    providers = parse_lock_file(lock_content)

    asserts.equals(env, 1, len(providers), "Should parse one provider")
    asserts.equals(env, "hashicorp/aws", providers[0].source, "Should handle provider without registry prefix")
    asserts.equals(env, "5.0.0", providers[0].version, "Should parse version")

    return unittest.end(env)

parse_provider_without_registry_prefix_test = unittest.make(_parse_provider_without_registry_prefix_test_impl)

def _parse_provider_with_many_hashes_test_impl(ctx):
    env = unittest.begin(ctx)

    lock_content = """\
provider "registry.terraform.io/hashicorp/null" {
  version = "3.2.4"
  hashes = [
    "h1:L5V05xwp/Gto1leRryuesxjMfgZwjb7oool4WS1UEFQ=",
    "zh:59f6b52ab4ff35739647f9509ee6d93d7c032985d9f8c6237d1f8a59471bbbe2",
    "zh:78d5eefdd9e494defcb3c68d282b8f96630502cac21d1ea161f53cfe9bb483b3",
    "zh:795c897119ff082133150121d39ff26cb5f89a730a2c8c26f3a9c1abf81a9c43",
    "zh:7b9c7b16f118fbc2b05a983817b8ce2f86df125857966ad356353baf4bff5c0a",
  ]
}
"""

    providers = parse_lock_file(lock_content)

    asserts.equals(env, 1, len(providers), "Should parse one provider")
    asserts.equals(env, 5, len(providers[0].hashes), "Should parse all five hashes")
    asserts.equals(env, "h1:L5V05xwp/Gto1leRryuesxjMfgZwjb7oool4WS1UEFQ=", providers[0].hashes[0], "First hash")
    asserts.equals(env, "zh:7b9c7b16f118fbc2b05a983817b8ce2f86df125857966ad356353baf4bff5c0a", providers[0].hashes[4], "Last hash")

    return unittest.end(env)

parse_provider_with_many_hashes_test = unittest.make(_parse_provider_with_many_hashes_test_impl)

def lock_parser_test_suite(name):
    """Create the test suite for lock parser tests.

    Args:
        name: (str) The name of the test suite.
    """
    parse_simple_provider_test(
        name = "parse_simple_provider_test",
    )
    parse_multiple_providers_test(
        name = "parse_multiple_providers_test",
    )
    parse_empty_file_test(
        name = "parse_empty_file_test",
    )
    parse_provider_without_registry_prefix_test(
        name = "parse_provider_without_registry_prefix_test",
    )
    parse_provider_with_many_hashes_test(
        name = "parse_provider_with_many_hashes_test",
    )

    native.test_suite(
        name = name,
        tests = [
            "parse_simple_provider_test",
            "parse_multiple_providers_test",
            "parse_empty_file_test",
            "parse_provider_without_registry_prefix_test",
            "parse_provider_with_many_hashes_test",
        ],
    )
