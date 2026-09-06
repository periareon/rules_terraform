"""Bazel rules for `terraform validate`.

The `build_validate_*_impl` helpers are consumed by `//opentofu` so both
engines share the same validate machinery — engine-specific file names,
output-group names, and ignore tags come from the `engine` parameter.
"""

load(":providers.bzl", "TerraformInfo")
load(":util.bzl", "module_dir", "rlocationpath")

visibility(["//opentofu/...", "//terraform/...", "//tests/..."])

# Tags that skip validation regardless of engine.
_GENERIC_IGNORE_TAGS = [
    "no_validate",
    "no_validation",
    "novalidate",
    "novalidation",
]

# Engine-scoped tags — `no_terraform_validate` skips ONLY the terraform
# aspect, `no_opentofu_validate` skips ONLY the opentofu aspect. Lets a
# mixed-engine repo opt one engine's aspect out without silencing both.
_ENGINE_IGNORE_TAGS = {
    "opentofu": [
        "no_opentofu_validate",
        "no_opentofu_validation",
        "no_opentofuvalidate",
        "noopentofuvalidate",
    ],
    "terraform": [
        "no_terraform_validate",
        "no_terraform_validation",
        "no_terraformvalidate",
        "noterraformvalidate",
    ],
}

def _should_skip(tags, engine):
    engine_tags = _ENGINE_IGNORE_TAGS.get(engine, [])
    for tag in tags:
        sanitized = tag.replace("-", "_").lower()
        if sanitized in _GENERIC_IGNORE_TAGS or sanitized in engine_tags:
            return True
    return False

def build_validate_aspect_impl(target, ctx, toolchain_type, *, engine):
    """Shared `validate` aspect implementation, parameterized by engine.

    Args:
        target: (Target) The Bazel target the aspect is running on.
        ctx: (ctx) The aspect context.
        toolchain_type: (str) Fully-qualified label string of the
            toolchain type the aspect should resolve.
        engine: (str) `"terraform"` or `"opentofu"`. Used for file names,
            the emitted output-group name (`<engine>_validate_checks`),
            the action mnemonic, and engine-scoped ignore-tag matching.

    Returns:
        (list[Provider]) Either empty or holding one `OutputGroupInfo`
        with the `<engine>_validate_checks` marker file.
    """
    if _should_skip(ctx.rule.attr.tags, engine):
        return []

    if TerraformInfo not in target:
        return []

    # `terraform_init_aspect` already assembled the directory the engine runs
    # in. Validate copies it and runs `validate` inside; there is nothing here
    # to lay out.
    module_directory = module_dir(target)
    if not module_directory:
        # terraform_init_aspect must run before validate; skip rather than
        # fail so a mis-configured target doesn't break every build.
        return []

    toolchain = ctx.toolchains[toolchain_type]
    marker = ctx.actions.declare_file("{}.{}_validate.ok".format(target.label.name, engine))

    args_data = {
        "marker": marker.path,
        "module_dir": module_directory.path,
        "terraform": toolchain.terraform.path,
    }

    args_file = ctx.actions.declare_file("{}.{}_validate_args.json".format(target.label.name, engine))
    ctx.actions.write(output = args_file, content = json.encode_indent(args_data))

    args = ctx.actions.args()
    args.add("-args", args_file.path)

    ctx.actions.run(
        mnemonic = "{}Validate".format(engine.capitalize()),
        progress_message = "{}Validate %{{label}}".format(engine.capitalize()),
        executable = ctx.executable._runner,
        inputs = depset([module_directory, args_file]),
        outputs = [marker],
        arguments = [args],
        tools = toolchain.all_files,
        env = ctx.configuration.default_shell_env,
    )

    return [OutputGroupInfo(**{"{}_validate_checks".format(engine): depset([marker])})]

def build_validate_test_impl(ctx, toolchain_type, *, engine):
    """Shared `validate_test` implementation, parameterized by engine.

    Args:
        ctx: (ctx) The rule context.
        toolchain_type: (str) Fully-qualified label string of the
            toolchain type the rule should resolve.
        engine: (str) `"terraform"` or `"opentofu"`. Used to name the args
            file so terraform and opentofu variants on the same underlying
            target never collide.

    Returns:
        (list[Provider]) `DefaultInfo` (executable + runfiles) and a
        `RunEnvironmentInfo` pointing at the args file.
    """
    module_directory = module_dir(ctx.attr.target)
    if not module_directory:
        fail("terraform_init_aspect must run on target. Ensure the target has terraform_init_aspect applied.")

    toolchain = ctx.toolchains[toolchain_type]

    args_data = {
        "marker": "",
        "module_dir": rlocationpath(module_directory, ctx.workspace_name),
        "terraform": rlocationpath(toolchain.terraform, ctx.workspace_name),
        "use_runfiles": True,
    }

    args_file = ctx.actions.declare_file("{}.{}_validate_args.json".format(ctx.label.name, engine))
    ctx.actions.write(output = args_file, content = json.encode_indent(args_data))

    is_windows = ctx.executable._test_runner.basename.endswith(".exe")
    executable = ctx.actions.declare_file("{}{}".format(ctx.label.name, ".exe" if is_windows else ""))
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable._test_runner,
        is_executable = True,
    )

    return [
        DefaultInfo(
            files = depset(),
            runfiles = ctx.runfiles(
                files = [args_file, module_directory],
                transitive_files = toolchain.all_files,
            ),
            executable = executable,
        ),
        RunEnvironmentInfo(
            environment = {
                "RULES_TERRAFORM_VALIDATE_ARGS_FILE": rlocationpath(args_file, ctx.workspace_name),
            },
        ),
    ]

# The engine-bound `terraform_validate_test` / `terraform_validate_aspect`
# are produced by the shared factory (`//terraform/private:engine_factory.bzl`)
# and re-exported from `//terraform:terraform_validate_test.bzl` /
# `//terraform:terraform_validate_aspect.bzl`.
