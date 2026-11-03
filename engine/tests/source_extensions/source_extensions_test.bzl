"""A module rule rejects files its engine would not load."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//engine:providers.bzl", "TerraformInfo")

visibility(["//engine/..."])

def _rejected_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "misplaced here")
    return analysistest.end(env)

rejected_source_test = analysistest.make(_rejected_impl, expect_failure = True)

def _accepted_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, TerraformInfo in target, "expected a module")
    return analysistest.end(env)

accepted_source_test = analysistest.make(_accepted_impl)
