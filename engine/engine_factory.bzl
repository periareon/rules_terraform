"""Engine-parametric rule factory.

Given an `engine_config`, produces the full set of engine-bound rules and
aspects that a `//<engine>` package exposes.

Both `//terraform` and `//tofu` top-level rule files load from a
single-call-per-engine sibling module (`//<engine>/private:engine_rules.bzl`
holds `<ENGINE>_RULES = make_engine_rules(engine = …)`) and just re-export
fields from that struct. The rule bodies never diverge between engines; the
config is the only knob.
"""

load(":cli.bzl", "make_cli_rule")
load(":env.bzl", "TEST_ENV_ATTRS")
load(":format.bzl", "build_fmt_aspect_impl", "build_fmt_test_impl", "make_formatter")
load(":init.bzl", "terraform_init_aspect")
load(":lock.bzl", "PROVIDERS_LOCK_ATTRS", "build_providers_lock")
load(":providers.bzl", "TerraformInfo")
load(":terraform.bzl", "PLAN_TEST_ATTRS", "RUNNER_ATTRS", "TEST_RUNNER_ATTRS", "build_runner", "make_module_rule")
load(":toolchain.bzl", "make_current_toolchain_rule")
load(":validate.bzl", "build_validate_aspect_impl", "build_validate_test_impl")

visibility(["//engine/...", "//terraform/...", "//tofu/..."])

def make_engine_rules(*, engine):
    """Return a struct of rules and aspects bound to one engine.

    Args:
        engine: (struct) The `engine_config`. Its `toolchain_type` is what
            every rule here requires and looks up via `ctx.toolchains[...]`;
            its name goes into docstrings, output groups and file names.

    Returns:
        (struct) Struct with fields: `binary`, `test`, `plan_test`,
        `validate_aspect`, `validate_test`, `fmt_aspect`, `fmt_test`,
        `providers_lock`, `formatter`, `cli`, `current_toolchain`, `module`.
        `plan_test` is the bare rule; the public `<engine>_plan_test.bzl`
        wraps it in a macro that adds the `requires-network` tag.

        `providers_lock` is a `bazel run` updater that runs real
        `<engine> providers lock -platform=<all>` under the resolved
        toolchain and writes the multi-platform lock file back to source.

    """
    toolchain_type = engine.toolchain_type
    name = engine.name

    def _binary_impl(ctx):
        return build_runner(ctx, toolchain_type, mode = "run")

    def _test_impl(ctx):
        return build_runner(ctx, toolchain_type, mode = "test")

    def _plan_test_impl(ctx):
        return build_runner(ctx, toolchain_type, mode = "plan")

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
Runs {engine} on a `terraform_module` root. Arguments pass through:
`bazel run //x:{engine} -- plan`, `-- apply`, `-- state list`. The engine
runs in a temp copy of the built module directory, providers and modules
already installed, so nothing is fetched at run time.

`init` is the exception: it installs that directory into the module's
source directory and initializes the backend there, so the native CLI
works in that directory afterwards.
""".format(engine = name),
        implementation = _binary_impl,
        attrs = RUNNER_ATTRS,
        executable = True,
        toolchains = [toolchain_type],
    )

    # OpenTofu has no `-junit-xml`; the runner builds the JUnit report from
    # `-json-into` instead (engine/runner/junit.go) and keeps that stream.
    test = rule(
        doc = """\
Runs `{engine} test` on the root module's `.tftest.hcl` files as a Bazel
test. Each `run` block is a JUnit test case in Bazel's XML report, and the
lock and module manifest the test ran against are kept as undeclared test
outputs. `--test_arg` is ignored.
""".format(engine = name),
        implementation = _test_impl,
        attrs = TEST_RUNNER_ATTRS,
        test = True,
        toolchains = [toolchain_type],
    )

    plan_test = rule(
        doc = """\
Runs `{engine} plan` as a Bazel test and keeps the plan for review:
`plan.tfplan`, `plan.json` and `plan.txt` under the undeclared test
outputs. Passes when the plan succeeds, or with `expect_no_changes` only
when it is empty. A plan reaches the backend and the provider APIs, so
credentials go through `--test_env`; the `{engine}_plan_test` macro tags
it `requires-network`.
""".format(engine = name),
        implementation = _plan_test_impl,
        attrs = PLAN_TEST_ATTRS,
        test = True,
        toolchains = [toolchain_type],
    )

    validate_aspect = aspect(
        implementation = _validate_aspect_impl,
        doc = "An aspect for running `{} validate` on targets with Terraform sources.".format(name),
        attrs = {
            "_runner": attr.label(
                cfg = "exec",
                executable = True,
                default = Label("//engine/validate:validator"),
            ),
        },
        required_providers = [TerraformInfo],
        toolchains = [toolchain_type],
        requires = [terraform_init_aspect],
    )

    validate_test = rule(
        implementation = _validate_test_impl,
        doc = "A rule for running `{} validate` on a Terraform target.".format(name),
        attrs = dict(TEST_ENV_ATTRS, **{
            "target": attr.label(
                doc = "The target to validate.",
                providers = [TerraformInfo],
                aspects = [terraform_init_aspect],
                mandatory = True,
            ),
            "_test_runner": attr.label(
                cfg = "target",
                executable = True,
                default = Label("//engine/validate:validator"),
            ),
        }),
        test = True,
        toolchains = [toolchain_type],
    )

    fmt_aspect = aspect(
        implementation = _fmt_aspect_impl,
        doc = "An aspect for running `{} fmt` on targets with Terraform sources.".format(name),
        attrs = {
            "_runner": attr.label(
                cfg = "exec",
                executable = True,
                default = Label("//engine/format:format_checker"),
            ),
        },
        required_providers = [TerraformInfo],
        toolchains = [toolchain_type],
    )

    fmt_test = rule(
        implementation = _fmt_test_impl,
        doc = "Fails when `{} fmt` would change a module's sources.".format(name),
        attrs = {
            "target": attr.label(
                doc = "The module to check.",
                providers = [TerraformInfo],
                mandatory = True,
            ),
            "_test_runner": attr.label(
                cfg = "target",
                executable = True,
                default = Label("//engine/format:format_checker"),
            ),
        },
        test = True,
        toolchains = [toolchain_type],
    )

    providers_lock = rule(
        doc = """\
`bazel run` target that writes a module's `.terraform.lock.hcl` with the
toolchain {engine}, recording hashes for every platform in `platforms` at
once, which the engine's own `init` does not do. Needs the network.
""".format(engine = name),
        implementation = _providers_lock_impl,
        attrs = PROVIDERS_LOCK_ATTRS,
        executable = True,
        toolchains = [toolchain_type],
    )

    return struct(
        module = make_module_rule(engine),
        binary = binary,
        test = test,
        plan_test = plan_test,
        validate_aspect = validate_aspect,
        validate_test = validate_test,
        fmt_aspect = fmt_aspect,
        fmt_test = fmt_test,
        providers_lock = providers_lock,
        formatter = make_formatter(engine),
        cli = make_cli_rule(engine),
        current_toolchain = make_current_toolchain_rule(engine),
    )
