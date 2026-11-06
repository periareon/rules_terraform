"""`bazel run @terraform` / `bazel run @tofu`: the CLI wrapper rule and its hub.

The wrapper is a small Go binary that resolves the toolchain-provided engine
binary via runfiles, `chdir`s to `$BUILD_WORKING_DIRECTORY`, and execs the
engine with the user's argv. See //engine/cli/cli.go for the runtime. The
hub repository rule generates the one-target `@<engine>` repository the
toolchains extension materializes automatically.
"""

load(":util.bzl", "rlocationpath")

visibility(["//engine/...", "//terraform/...", "//tofu/..."])

def make_cli_rule(engine):
    """The `bazel run` wrapper rule for one engine.

    Args:
        engine: (struct) The `engine_config`.

    Returns:
        (rule) An executable rule that runs the engine in `$BUILD_WORKING_DIRECTORY`.
    """
    toolchain_type = engine.toolchain_type

    def _impl(ctx):
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

    return rule(
        doc = "`bazel run` wrapper that runs `{}` in $BUILD_WORKING_DIRECTORY.".format(engine.name),
        implementation = _impl,
        attrs = {
            "_cli": attr.label(
                cfg = "target",
                executable = True,
                default = Label("//engine/cli"),
            ),
        },
        toolchains = [toolchain_type],
        executable = True,
    )

_HUB_BUILD = """\
load("{hub_bzl}", "{rule_name}")

{rule_name}(
    name = "{name}",
    visibility = ["//visibility:public"],
)
"""

def _cli_hub_impl(repository_ctx):
    repository_ctx.file(
        "WORKSPACE.bazel",
        'workspace(name = "{}")\n'.format(repository_ctx.name),
    )
    repository_ctx.file("BUILD.bazel", _HUB_BUILD.format(
        hub_bzl = repository_ctx.attr.hub_bzl,
        rule_name = repository_ctx.attr.rule_name,
        name = repository_ctx.attr.target_name,
    ))

    return repository_ctx.repo_metadata(reproducible = True)

cli_hub = repository_rule(
    doc = "Materializes a one-target hub repository whose top-level target is the CLI wrapper.",
    implementation = _cli_hub_impl,
    attrs = {
        "hub_bzl": attr.string(
            doc = "Label of the `.bzl` file that exports `rule_name`.",
            mandatory = True,
        ),
        "rule_name": attr.string(
            doc = "The CLI wrapper rule to instantiate, e.g. `terraform_cli`.",
            mandatory = True,
        ),
        "target_name": attr.string(
            doc = "Name of the one target; the same as the repository's so `bazel run @<name>` resolves.",
            mandatory = True,
        ),
    },
)
