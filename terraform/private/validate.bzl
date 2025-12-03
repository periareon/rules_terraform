"""Bazel rules for `terraform validate`.

The `build_validate_*_impl` helpers are consumed by `//opentofu` so both
engines share the same validate machinery — engine-specific file names,
output-group names, and ignore tags come from the `engine` parameter.
"""

load(":args.bzl", "pick_root_file")
load(":providers.bzl", "TerraformInfo")
load(":util.bzl", "rlocationpath", "terraform_init_dir")

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

def _collect_validate_inputs(target_info, workspace_name, label, *, use_runfiles):
    """Shared setup for both validate aspect and validate test.

    Args:
        target_info: (TerraformInfo) Provider from the module under test.
        workspace_name: (str) Bazel workspace name.
        label: (Label) The originating target's label (used for fail messages).
        use_runfiles: (bool) When True (test rule), file-map values are
            rlocationpaths the runtime resolves via `runfiles.Rlocation`.
            When False (aspect action), values are action-root paths.

    Returns:
        (struct|None) None if the target has no source .tf files; otherwise
        a struct with `all_files`, `all_files_depsets`, `files_json`,
        `lock_file`, and `root_file_rloc`.
    """
    srcs = [src for src in target_info.srcs.to_list() if src.is_source]
    if not srcs:
        return None

    deps_list = target_info.deps.to_list()

    all_files = list(srcs)
    all_files_depsets = [depset(srcs)]
    for dep_info in deps_list:
        all_files_depsets.append(dep_info.srcs)
        all_files_depsets.append(dep_info.data)

    lock_file = target_info.lock
    if lock_file:
        all_files.append(lock_file)

    files_map = {rlocationpath(src, workspace_name): src for src in srcs}
    for dep_info in deps_list:
        for dep_file in dep_info.srcs.to_list():
            files_map[rlocationpath(dep_file, workspace_name)] = dep_file
        for dep_file in dep_info.data.to_list():
            files_map[rlocationpath(dep_file, workspace_name)] = dep_file
    if lock_file:
        files_map[rlocationpath(lock_file, workspace_name)] = lock_file

    if use_runfiles:
        # Test rule: the runtime resolves each rlocationpath via runfiles.
        # Since keys were built as `rlocationpath(f)`, values equal keys.
        files_json = {rp: rp for rp in files_map}
    else:
        # Aspect action: values are action-root paths.
        files_json = {rp: f.path for rp, f in files_map.items()}

    # Anchor the module root to a real runfile — runfiles is a manifest of
    # files, not a directory tree, so directory-string prefixes aren't
    # independently resolvable. See //terraform/private/validate/validator.go.
    root_src = pick_root_file(srcs, "validate {}".format(label))
    root_file_rloc = rlocationpath(root_src, workspace_name)

    return struct(
        all_files = all_files,
        all_files_depsets = all_files_depsets,
        files_json = files_json,
        lock_file = lock_file,
        root_file_rloc = root_file_rloc,
    )

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

    collected = _collect_validate_inputs(
        target[TerraformInfo],
        ctx.workspace_name,
        target.label,
        use_runfiles = False,
    )
    if collected == None:
        return []

    terraform_dir = terraform_init_dir(target)
    if not terraform_dir:
        # terraform_init_aspect must run before validate; skip rather than
        # fail so a mis-configured target doesn't break every build.
        return []

    toolchain = ctx.toolchains[toolchain_type]
    marker = ctx.actions.declare_file("{}.{}_validate.ok".format(target.label.name, engine))

    args_data = {
        "files": collected.files_json,
        "marker": marker.path,
        "root_file": collected.root_file_rloc,
        "terraform": toolchain.terraform.path,
        "terraform_dir": terraform_dir.path,
    }
    if target[TerraformInfo].module_sources:
        args_data["module_sources"] = target[TerraformInfo].module_sources

    args_file = ctx.actions.declare_file("{}.{}_validate_args.json".format(target.label.name, engine))
    ctx.actions.write(output = args_file, content = json.encode_indent(args_data))

    args = ctx.actions.args()
    args.add("-args", args_file.path)

    ctx.actions.run(
        mnemonic = "{}Validate".format(engine.capitalize()),
        progress_message = "{}Validate %{{label}}".format(engine.capitalize()),
        executable = ctx.executable._runner,
        inputs = depset(
            [terraform_dir, args_file] + collected.all_files,
            transitive = collected.all_files_depsets,
        ),
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
    collected = _collect_validate_inputs(
        ctx.attr.target[TerraformInfo],
        ctx.workspace_name,
        ctx.attr.target.label,
        use_runfiles = True,
    )
    if collected == None:
        fail("No source files found in target")

    terraform_dir = terraform_init_dir(ctx.attr.target)
    if not terraform_dir:
        fail("terraform_init_aspect must run on target. Ensure the target has terraform_init_aspect applied.")

    toolchain = ctx.toolchains[toolchain_type]

    args_data = {
        "files": collected.files_json,
        "marker": "",
        "root_file": collected.root_file_rloc,
        "terraform": rlocationpath(toolchain.terraform, ctx.workspace_name),
        "terraform_dir": rlocationpath(terraform_dir, ctx.workspace_name),
        "use_runfiles": True,
    }
    if ctx.attr.target[TerraformInfo].module_sources:
        args_data["module_sources"] = ctx.attr.target[TerraformInfo].module_sources

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
                files = [args_file, terraform_dir] + collected.all_files,
                transitive_files = depset(transitive = collected.all_files_depsets + [toolchain.all_files]),
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
