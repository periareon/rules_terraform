"""Unit tests for the git module-source parser."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//terraform/private:git_source.bzl", "is_commit", "parse_git_source")

# buildifier: disable=bzl-visibility
load("//terraform/private:registry.bzl", "is_registry_source")

def _forced_https_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_git_source("git::https://git.example.com/acme/terraform-vpc.git?ref=v1.4.0")
    asserts.equals(env, "https://git.example.com/acme/terraform-vpc.git", parsed.remote)
    asserts.equals(env, "v1.4.0", parsed.ref)
    asserts.equals(env, "", parsed.subdir)
    return unittest.end(env)

forced_https_test = unittest.make(_forced_https_test_impl)

def _forced_ssh_with_subdir_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_git_source("git::ssh://git@git.example.com/acme/terraform-modules.git//modules/vpc?ref=v2.0.0&depth=1")
    asserts.equals(env, "ssh://git@git.example.com/acme/terraform-modules.git", parsed.remote, "the scheme's // is not a subdir separator")
    asserts.equals(env, "v2.0.0", parsed.ref)
    asserts.equals(env, "modules/vpc", parsed.subdir)
    return unittest.end(env)

forced_ssh_with_subdir_test = unittest.make(_forced_ssh_with_subdir_test_impl)

def _scp_like_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_git_source("git@git.example.com:acme/terraform-vpc.git?ref=main")
    asserts.equals(env, "git@git.example.com:acme/terraform-vpc.git", parsed.remote)
    asserts.equals(env, "main", parsed.ref)
    asserts.equals(env, "", parsed.subdir)
    return unittest.end(env)

scp_like_test = unittest.make(_scp_like_test_impl)

def _github_shorthand_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_git_source("github.com/acme/terraform-vpc//modules/subnets?ref=v1.4.0")
    asserts.equals(env, "https://github.com/acme/terraform-vpc.git", parsed.remote, "the shorthand becomes the https remote go-getter uses")
    asserts.equals(env, "v1.4.0", parsed.ref)
    asserts.equals(env, "modules/subnets", parsed.subdir)
    return unittest.end(env)

github_shorthand_test = unittest.make(_github_shorthand_test_impl)

def _no_ref_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_git_source("git::https://git.example.com/acme/terraform-vpc.git")
    asserts.equals(env, "", parsed.ref, "no ?ref= means the default branch")
    return unittest.end(env)

no_ref_test = unittest.make(_no_ref_test_impl)

def _not_git_test_impl(ctx):
    env = unittest.begin(ctx)
    for source in [
        "cloudposse/label/null",
        "app.terraform.io/acme/vpc/aws",
        "./modules/vpc",
        "../vpc",
        "https://example.com/vpc.zip",
        "s3::https://s3.amazonaws.com/bucket/vpc.zip",
        "",
    ]:
        asserts.equals(env, None, parse_git_source(source), "{} is not a git source".format(repr(source)))
    return unittest.end(env)

not_git_test = unittest.make(_not_git_test_impl)

def _registry_classifier_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, is_registry_source("github.com/acme/terraform-vpc"), "the GitHub shorthand has three segments but is git")
    asserts.false(env, is_registry_source("git::https://github.com/acme/terraform-vpc.git?ref=v1"))
    asserts.false(env, is_registry_source("git@github.com:acme/terraform-vpc.git"))
    asserts.true(env, is_registry_source("cloudposse/label/null"))
    asserts.true(env, is_registry_source("terraform-aws-modules/eks/aws//modules/karpenter"))
    return unittest.end(env)

registry_classifier_test = unittest.make(_registry_classifier_test_impl)

def _is_commit_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, is_commit("0123456789abcdef0123456789abcdef01234567"))
    asserts.false(env, is_commit("0123456789abcdef"), "an abbreviated id is resolved like a tag")
    asserts.false(env, is_commit("v1.4.0"))
    asserts.false(env, is_commit("main"))
    asserts.false(env, is_commit(""))
    return unittest.end(env)

is_commit_test = unittest.make(_is_commit_test_impl)

def git_source_test_suite(name):
    """Declare the git source parser tests.

    Args:
        name: (str) Name of the suite.
    """
    unittest.suite(
        name,
        forced_https_test,
        forced_ssh_with_subdir_test,
        scp_like_test,
        github_shorthand_test,
        no_ref_test,
        not_git_test,
        registry_classifier_test,
        is_commit_test,
    )
