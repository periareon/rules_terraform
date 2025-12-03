"""Engine-parametric rule factory.

Given an engine name (`"terraform"` / `"opentofu"`) and the corresponding
toolchain-type label, produces the full set of engine-bound rules and
aspects that a `//<engine>` package exposes.

Both `//terraform` and `//opentofu` top-level rule files load from a
single-call-per-engine sibling module (e.g. `//terraform/private:engine_rules.bzl`
holds `TERRAFORM_RULES = make_engine_rules(...)`) and just re-export
fields from that struct. The rule bodies never diverge between engines —
`toolchain_type` is the only knob.
"""

load(":format.bzl", "build_fmt_aspect_impl", "build_fmt_test_impl")
load(":init.bzl", "terraform_init_aspect")
load(":lock.bzl", "PROVIDERS_LOCK_ATTRS", "build_providers_lock")
load(":providers.bzl", "TerraformInfo")
load(":terraform.bzl", "RUNNER_ATTRS", "build_runner")
load(":validate.bzl", "build_validate_aspect_impl", "build_validate_test_impl")

visibility(["//opentofu/...", "//terraform/..."])

def make_engine_rules(*, engine, toolchain_type):
    """Return a struct of rules and aspects bound to the given toolchain.

    Args:
        engine: (str) Human-readable engine name (`terraform`,
            `opentofu`) used only in docstrings.
        toolchain_type: (str) Fully-qualified label string of the
            toolchain type the generated rules should require. Rule
            implementations look up the resolved toolchain by this label
            via `ctx.toolchains[...]`.

    Returns:
        (struct) Struct with fields: `binary`, `test`, `validate_aspect`,
        `validate_test`, `fmt_aspect`, `fmt_test`, `providers_lock`.

        `providers_lock` is a `bazel run` updater that runs real
        `<engine> providers lock -platform=<all>` under the resolved
        toolchain and writes the multi-platform lock file back to source.

    """

    def _binary_impl(ctx):
        return build_runner(ctx, toolchain_type, test_mode = False)

    def _test_impl(ctx):
        return build_runner(ctx, toolchain_type, test_mode = True)

    def _validate_aspect_impl(target, ctx):
        return build_validate_aspect_impl(target, ctx, toolchain_type, engine = engine)

    def _validate_test_impl(ctx):
        return build_validate_test_impl(ctx, toolchain_type, engine = engine)

    def _fmt_aspect_impl(target, ctx):
        return build_fmt_aspect_impl(target, ctx, toolchain_type, engine = engine)

    def _fmt_test_impl(ctx):
        return build_fmt_test_impl(ctx, toolchain_type, engine = engine)

    def _providers_lock_impl(ctx):
        return build_providers_lock(ctx, toolchain_type)

    binary = rule(
        doc = """\
Wraps the {engine} binary for a `terraform_module` root. Invoke via
`bazel run` — any subcommand and args are passed straight through, so
`bazel run //x:{engine} -- plan`, `... -- apply`, `... -- state list`, etc.
mirror the nominal CLI.

The `.terraform` directory is assembled hermetically by
`terraform_init_aspect`; providers and modules come from Bazel-managed
dependencies rather than the network.
""".format(engine = engine),
        implementation = _binary_impl,
        attrs = RUNNER_ATTRS,
        executable = True,
        toolchains = [toolchain_type],
    )

    test = rule(
        doc = """\
Runs {engine}'s native HCL test framework (`{engine} test`) on the root
module as a Bazel test. Test cases live in `.tftest.hcl` files. Fully
hermetic — the .terraform directory is assembled by the init aspect from
Bazel-managed deps.

Bazel `--test_arg` values are intentionally ignored so the surface stays
predictable — every run executes the module's `.tftest.hcl` files.
""".format(engine = engine),
        implementation = _test_impl,
        attrs = RUNNER_ATTRS,
        test = True,
        toolchains = [toolchain_type],
    )

    validate_aspect = aspect(
        implementation = _validate_aspect_impl,
        doc = "An aspect for running `{} validate` on targets with Terraform sources.".format(engine),
        attrs = {
            "_runner": attr.label(
                cfg = "exec",
                executable = True,
                default = Label("//terraform/private/validate:validator"),
            ),
        },
        required_providers = [TerraformInfo],
        toolchains = [toolchain_type],
        requires = [terraform_init_aspect],
    )

    validate_test = rule(
        implementation = _validate_test_impl,
        doc = "A rule for running `{} validate` on a Terraform target.".format(engine),
        attrs = {
            "target": attr.label(
                doc = "The target to validate.",
                providers = [TerraformInfo],
                aspects = [terraform_init_aspect],
                mandatory = True,
            ),
            "_test_runner": attr.label(
                cfg = "target",
                executable = True,
                default = Label("//terraform/private/validate:validator"),
            ),
        },
        test = True,
        toolchains = [toolchain_type],
    )

    fmt_aspect = aspect(
        implementation = _fmt_aspect_impl,
        doc = "An aspect for running `{} fmt` on targets with Terraform sources.".format(engine),
        attrs = {
            "_runner": attr.label(
                cfg = "exec",
                executable = True,
                default = Label("//terraform/private/format:format_checker"),
            ),
        },
        required_providers = [TerraformInfo],
        toolchains = [toolchain_type],
    )

    fmt_test = rule(
        implementation = _fmt_test_impl,
        doc = "A rule for running `{} fmt` on a Terraform target.".format(engine),
        attrs = {
            "target": attr.label(
                providers = [TerraformInfo],
                mandatory = True,
            ),
            "_test_runner": attr.label(
                cfg = "target",
                executable = True,
                default = Label("//terraform/private/format:format_checker"),
            ),
        },
        test = True,
        toolchains = [toolchain_type],
    )

    providers_lock = rule(
        doc = """\
Regenerates `.terraform.lock.hcl` for a `terraform_module` by running
real `{engine} providers lock -platform=<all>` under the toolchain-fetched
{engine} binary. `bazel run` writes the multi-platform result back to
source — the one path that produces hashes for platforms Bazel didn't
resolve for the current build.
""".format(engine = engine),
        implementation = _providers_lock_impl,
        attrs = PROVIDERS_LOCK_ATTRS,
        executable = True,
        toolchains = [toolchain_type],
    )

    return struct(
        binary = binary,
        test = test,
        validate_aspect = validate_aspect,
        validate_test = validate_test,
        fmt_aspect = fmt_aspect,
        fmt_test = fmt_test,
        providers_lock = providers_lock,
    )
