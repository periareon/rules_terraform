"""Terraform toolchain implementation"""

load(":util.bzl", "rlocationpath")

TOOLCHAIN_TYPE = str(Label("//terraform:toolchain_type"))

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

def _current_terraform_toolchain_impl(ctx):
    toolchain = ctx.toolchains[TOOLCHAIN_TYPE]

    return [
        DefaultInfo(
            files = toolchain.all_files,
            runfiles = ctx.runfiles(transitive_files = toolchain.all_files),
        ),
        toolchain,
        toolchain.make_variable_info,
    ]

current_terraform_toolchain = rule(
    doc = "Access the `terraform_toolchain` for the current configuration.",
    implementation = _current_terraform_toolchain_impl,
    toolchains = [TOOLCHAIN_TYPE],
)

def _current_terraform_binary_impl(ctx):
    toolchain = ctx.toolchains[TOOLCHAIN_TYPE]

    terraform = toolchain.terraform
    is_windows = terraform.basename.endswith(".exe")
    executable = ctx.actions.declare_file("{}{}".format(ctx.label.name, ".exe" if is_windows else ""))

    ctx.actions.symlink(
        output = executable,
        target_file = terraform,
        is_executable = True,
    )

    return [
        DefaultInfo(
            executable = executable,
            files = depset([executable]),
            runfiles = ctx.runfiles(transitive_files = toolchain.all_files),
        ),
    ]

current_terraform_binary = rule(
    doc = "Access the `terraform_toolchain.terraform` target for the current configuration.",
    implementation = _current_terraform_binary_impl,
    toolchains = [TOOLCHAIN_TYPE],
    executable = True,
)
