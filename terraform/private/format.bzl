"""Bazel rules for `terraform fmt`.

`build_fmt_*_impl` helpers are consumed by `//tofu` for the tofu-side
rules — engine-specific file names, output-group names, and ignore tags
come from the `engine` parameter.
"""

load(":providers.bzl", "TerraformInfo")
load(":toolchain.bzl", "TOOLCHAIN_TYPE")
load(":util.bzl", "rlocationpath")

visibility(["//terraform/...", "//tests/...", "//tofu/..."])

# Tags that skip fmt regardless of engine.
_GENERIC_IGNORE_TAGS = [
    "no_format",
    "no_fmt",
    "noformat",
    "nofmt",
]

# Engine-scoped tags — `no_terraform_format` skips ONLY the terraform
# aspect, `no_tofu_format` skips ONLY the tofu aspect.
_ENGINE_IGNORE_TAGS = {
    "terraform": [
        "no_terraform_format",
        "no_terraform_fmt",
        "no_terraformfmt",
        "noterraformfmt",
    ],
    "tofu": [
        "no_tofu_format",
        "no_tofu_fmt",
        "no_tofufmt",
        "notofufmt",
    ],
}

def _should_skip(tags, engine):
    engine_tags = _ENGINE_IGNORE_TAGS.get(engine, [])
    for tag in tags:
        sanitized = tag.replace("-", "_").lower()
        if sanitized in _GENERIC_IGNORE_TAGS or sanitized in engine_tags:
            return True
    return False

def build_fmt_aspect_impl(target, ctx, toolchain_type, *, engine):
    """Shared `fmt` aspect implementation, parameterized by engine.

    Args:
        target: (Target) The Bazel target the aspect is running on.
        ctx: (ctx) The aspect context.
        toolchain_type: (str) Fully-qualified label string of the
            toolchain type the aspect should resolve.
        engine: (str) `"terraform"` or `"tofu"`. Used for file names,
            the emitted output-group name (`<engine>_fmt_checks`), the
            action mnemonic, and engine-scoped ignore-tag matching.

    Returns:
        (list[Provider]) Either empty or holding one `OutputGroupInfo`
        with the `<engine>_fmt_checks` marker file.
    """
    if _should_skip(ctx.rule.attr.tags, engine):
        return []

    if TerraformInfo not in target:
        return []

    terraform_info = target[TerraformInfo]

    srcs = [src for src in terraform_info.srcs.to_list() if src.is_source]
    if not srcs:
        return []

    toolchain = ctx.toolchains[toolchain_type]

    marker = ctx.actions.declare_file("{}.{}_fmt.ok".format(target.label.name, engine))

    args = ctx.actions.args()
    args.add("-terraform", toolchain.terraform)
    args.add("-marker", marker)
    args.add_all(srcs, format_each = "-src=%s")

    ctx.actions.run(
        mnemonic = "{}Fmt".format(engine.capitalize()),
        progress_message = "{}Fmt %{{label}}".format(engine.capitalize()),
        executable = ctx.executable._runner,
        inputs = depset(srcs),
        outputs = [marker],
        arguments = [args],
        tools = toolchain.all_files,
    )

    return [OutputGroupInfo(**{"{}_fmt_checks".format(engine): depset([marker])})]

def build_fmt_test_impl(ctx, toolchain_type, *, engine):
    """Shared `fmt_test` implementation, parameterized by engine.

    Args:
        ctx: (ctx) The rule context.
        toolchain_type: (str) Fully-qualified label string of the
            toolchain type the rule should resolve.
        engine: (str) `"terraform"` or `"tofu"`. Used to name the args
            file so terraform and tofu variants on the same underlying
            target never collide.

    Returns:
        (list[Provider]) `DefaultInfo` (executable + runfiles) and a
        `RunEnvironmentInfo` pointing at the args file.
    """
    target_info = ctx.attr.target[TerraformInfo]

    srcs = [src for src in target_info.srcs.to_list() if src.is_source]

    workspace_name = ctx.workspace_name

    toolchain = ctx.toolchains[toolchain_type]

    src_paths = [rlocationpath(src, workspace_name) for src in srcs]
    args_json = json.encode({
        "srcs": src_paths,
        "terraform": rlocationpath(toolchain.terraform, workspace_name),
    })

    args_file = ctx.actions.declare_file("{}.{}_fmt_args.json".format(ctx.label.name, engine))
    ctx.actions.write(
        output = args_file,
        content = args_json,
    )

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
            runfiles = ctx.runfiles(files = [args_file] + srcs, transitive_files = toolchain.all_files),
            executable = executable,
        ),
        RunEnvironmentInfo(
            environment = {
                "RULES_TERRAFORM_FORMAT_ARGS_FILE": rlocationpath(args_file, ctx.workspace_name),
            },
        ),
    ]

# The engine-bound `terraform_fmt_aspect` / `terraform_fmt_test` are
# produced by `//terraform/private:engine_factory.bzl` and re-exported
# from `//terraform:terraform_fmt_aspect.bzl` /
# `//terraform:terraform_fmt_test.bzl`. The formatter rules below are
# separate developer-facing targets: `bazel run //terraform:format` (or
# `//tofu:format`) rewrites the `.tf` sources of every module in the
# workspace with the toolchain engine's `fmt`, so nothing needs installing
# on the host.

def _formatter_impl(ctx):
    toolchain = ctx.toolchains[ctx.attr._toolchain_type]

    is_windows = ctx.executable._formatter.basename.endswith(".exe")
    executable = ctx.actions.declare_file("{}{}".format(ctx.label.name, ".exe" if is_windows else ""))
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable._formatter,
        is_executable = True,
    )

    return [
        DefaultInfo(
            files = depset(),
            runfiles = ctx.runfiles(transitive_files = toolchain.all_files),
            executable = executable,
        ),
        RunEnvironmentInfo(
            environment = {
                "TERRAFORM_RLOCATIONPATH": rlocationpath(toolchain.terraform, ctx.workspace_name),
            },
        ),
    ]

def _make_formatter(toolchain_type, engine):
    return rule(
        doc = """`bazel run` target that rewrites the `.tf` sources of every
module in the workspace (or of the targets given as arguments) with
`{} fmt`, using the toolchain binary.""".format(engine),
        implementation = _formatter_impl,
        attrs = {
            "_formatter": attr.label(
                cfg = "exec",
                executable = True,
                default = Label("//terraform/private/format:formatter"),
            ),
            "_toolchain_type": attr.string(default = toolchain_type),
        },
        executable = True,
        toolchains = [toolchain_type],
    )

terraform_formatter = _make_formatter(TOOLCHAIN_TYPE, "terraform")
tofu_formatter = _make_formatter(str(Label("//tofu:toolchain_type")), "tofu")
