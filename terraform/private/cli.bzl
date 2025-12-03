"""`bazel run @terraform` / `bazel run @opentofu` wrapper rules and hubs.

The wrapper is a small Go binary that resolves the toolchain-provided
engine binary via runfiles, `chdir`s to `$BUILD_WORKING_DIRECTORY`, and
execs the engine with the user's argv. See //terraform/private/cli/cli.go
for the runtime. The hub repository rules (`terraform_cli_hub`,
`opentofu_cli_hub`) generate the `@terraform` and `@opentofu` external
repositories the toolchain extensions materialize automatically.
"""

load(":util.bzl", "rlocationpath")

# Extension-generated `@terraform` / `@opentofu` hub BUILD files load
# `terraform_cli` / `opentofu_cli` from here, so the file has to be
# publicly loadable (same story as //terraform/private:terraform.bzl).
visibility("public")

_TERRAFORM_TOOLCHAIN_TYPE = str(Label("//terraform:toolchain_type"))
_OPENTOFU_TOOLCHAIN_TYPE = str(Label("//opentofu:toolchain_type"))

def _build_cli(ctx, toolchain_type):
    toolchain = ctx.toolchains[toolchain_type]

    is_windows = ctx.executable._cli.basename.endswith(".exe")
    executable = ctx.actions.declare_file("{}{}".format(ctx.label.name, ".exe" if is_windows else ""))
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable._cli,
        is_executable = True,
    )

    runfiles = ctx.runfiles(transitive_files = toolchain.all_files)
    runfiles = runfiles.merge(ctx.attr._cli[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            executable = executable,
            runfiles = runfiles,
        ),
        RunEnvironmentInfo(environment = {
            "TERRAFORM_RLOCATIONPATH": rlocationpath(toolchain.terraform, ctx.workspace_name),
        }),
    ]

_CLI_ATTRS = {
    "_cli": attr.label(
        cfg = "target",
        executable = True,
        default = Label("//terraform/private/cli"),
    ),
}

def _terraform_cli_impl(ctx):
    return _build_cli(ctx, _TERRAFORM_TOOLCHAIN_TYPE)

terraform_cli = rule(
    doc = "`bazel run` wrapper that runs `terraform` in $BUILD_WORKING_DIRECTORY.",
    implementation = _terraform_cli_impl,
    attrs = _CLI_ATTRS,
    toolchains = [_TERRAFORM_TOOLCHAIN_TYPE],
    executable = True,
)

def _opentofu_cli_impl(ctx):
    return _build_cli(ctx, _OPENTOFU_TOOLCHAIN_TYPE)

opentofu_cli = rule(
    doc = "`bazel run` wrapper that runs `tofu` in $BUILD_WORKING_DIRECTORY.",
    implementation = _opentofu_cli_impl,
    attrs = _CLI_ATTRS,
    toolchains = [_OPENTOFU_TOOLCHAIN_TYPE],
    executable = True,
)

_TERRAFORM_HUB_BUILD = """\
load("@rules_terraform//terraform/private:cli.bzl", "terraform_cli")

terraform_cli(
    name = "terraform",
    visibility = ["//visibility:public"],
)
"""

_OPENTOFU_HUB_BUILD = """\
load("@rules_terraform//terraform/private:cli.bzl", "opentofu_cli")

opentofu_cli(
    name = "opentofu",
    visibility = ["//visibility:public"],
)
"""

def _cli_hub_impl(repository_ctx):
    repository_ctx.file(
        "WORKSPACE.bazel",
        'workspace(name = "{}")\n'.format(repository_ctx.name),
    )
    repository_ctx.file("BUILD.bazel", repository_ctx.attr.build_content)

_cli_hub = repository_rule(
    doc = "Materializes a one-target hub repo whose top-level `<name>` alias is the CLI wrapper.",
    implementation = _cli_hub_impl,
    attrs = {
        "build_content": attr.string(mandatory = True),
    },
)

def terraform_cli_hub(name):
    """Materialize `@<name>` (typically `@terraform`) with a `terraform_cli` target."""
    _cli_hub(name = name, build_content = _TERRAFORM_HUB_BUILD)

def opentofu_cli_hub(name):
    """Materialize `@<name>` (typically `@opentofu`) with an `opentofu_cli` target."""
    _cli_hub(name = name, build_content = _OPENTOFU_HUB_BUILD)
