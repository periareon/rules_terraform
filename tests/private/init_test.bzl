"""Test rule for verifying `terraform_init_aspect` output.

Test-only: this rule lives under `//tests/private` because it exists solely
to assert on the shape of the module directory the aspect produces. It
isn't part of the public rules_terraform API.

Backed by a Go binary (`initcheck`) that reads a multiline args file whose
rlocationpath is delivered via `RULES_TERRAFORM_INITCHECK_ARGS_FILE`.
"""

# buildifier: disable=bzl-visibility
load("//terraform/private:init.bzl", "terraform_init_aspect")

# buildifier: disable=bzl-visibility
load("//terraform/private:providers.bzl", "TerraformInfo")

# buildifier: disable=bzl-visibility
load("//terraform/private:util.bzl", "module_dir", "rlocationpath")

visibility(["//tests/..."])

def _terraform_init_test_impl(ctx):
    module_directory = module_dir(ctx.attr.target)
    if not module_directory:
        fail("terraform_init_aspect did not produce a module directory")

    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.add("-dir=" + rlocationpath(module_directory, ctx.workspace_name))
    for path in ctx.attr.expected_files:
        args.add("-expected=" + path)

    args_file = ctx.actions.declare_file("{}.initcheck.args".format(ctx.label.name))
    ctx.actions.write(output = args_file, content = args)

    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable._initcheck,
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [ctx.executable._initcheck, args_file, module_directory])
    runfiles = runfiles.merge(ctx.attr._initcheck[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        testing.TestEnvironment({
            "RULES_TERRAFORM_INITCHECK_ARGS_FILE": rlocationpath(args_file, ctx.workspace_name),
        }),
    ]

terraform_init_test = rule(
    doc = "Tests that terraform_init_aspect produces expected files in the .terraform directory.",
    test = True,
    implementation = _terraform_init_test_impl,
    attrs = {
        "expected_files": attr.string_list(
            doc = "Paths expected inside the module directory, relative to it.",
            mandatory = True,
        ),
        "target": attr.label(
            doc = "The terraform_module target to apply the init aspect to.",
            providers = [TerraformInfo],
            aspects = [terraform_init_aspect],
            mandatory = True,
        ),
        "_initcheck": attr.label(
            executable = True,
            cfg = "target",
            default = Label("//tests/private/initcheck"),
        ),
    },
)
