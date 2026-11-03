"""The toolchain rule every engine's toolchain repositories instantiate."""

load(":util.bzl", "rlocationpath")

visibility(["//engine/...", "//terraform/...", "//tofu/..."])

def _terraform_toolchain_impl(ctx):
    make_variable_info = platform_common.TemplateVariableInfo({
        "TERRAFORM": ctx.executable.terraform.path,
        "TERRAFORM_RLOCATIONPATH": rlocationpath(ctx.executable.terraform, ctx.workspace_name),
    })

    all_files = depset(transitive = [
        ctx.attr.terraform[DefaultInfo].default_runfiles.files if ctx.attr.terraform[DefaultInfo].default_runfiles else depset(),
        ctx.attr.terraform[DefaultInfo].files,
    ])

    return [
        platform_common.ToolchainInfo(
            make_variable_info = make_variable_info,
            terraform = ctx.executable.terraform,
            all_files = all_files,
        ),
        make_variable_info,
    ]

terraform_toolchain = rule(
    doc = "A toolchain for building Terraform targets.",
    implementation = _terraform_toolchain_impl,
    attrs = {
        "terraform": attr.label(
            doc = "The path to a Terraform binary.",
            cfg = "exec",
            executable = True,
            allow_single_file = True,
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The version of the terraform binary.",
            mandatory = True,
        ),
    },
)

def make_current_toolchain_rule(engine):
    """A rule exposing the engine's resolved toolchain for the current configuration.

    Args:
        engine: (struct) The `engine_config`.

    Returns:
        (rule) The `current_<engine>_toolchain` rule.
    """
    toolchain_type = engine.toolchain_type

    def _impl(ctx):
        toolchain = ctx.toolchains[toolchain_type]

        return [
            DefaultInfo(
                files = toolchain.all_files,
                runfiles = ctx.runfiles(transitive_files = toolchain.all_files),
            ),
            toolchain,
            toolchain.make_variable_info,
        ]

    return rule(
        doc = "Access the `{}` toolchain for the current configuration.".format(engine.name),
        implementation = _impl,
        toolchains = [toolchain_type],
    )
