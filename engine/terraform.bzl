"""Bazel terraform rules.

The `RUNNER_ATTRS` / `TEST_RUNNER_ATTRS` / `build_runner` helpers here are consumed by `//tofu`
so the same rule bodies power both engines.
"""

load(":env.bzl", "ENV_ATTRS", "TEST_ENV_ATTRS", "engine_env")
load(":init.bzl", "terraform_init_aspect")
load(":platforms.bzl", "PLATFORM_CONSTRAINT_LABELS", "detect_platform")
load(
    ":providers.bzl",
    "TerraformExternalModuleInfo",
    "TerraformInfo",
    "TerraformModuleGroupInfo",
    "TerraformProviderGroupInfo",
    "TerraformProviderInfo",
)
load(":util.bzl", "module_dir", "rlocationpath", "staged_dir", "staged_path")

visibility(["//engine/...", "//terraform/...", "//tofu/..."])

def _module_root_dir(label, srcs, data):
    """Validate the module's file layout and return its directory.

    A Terraform module *is* a directory — the engine loads every `.tf` file
    in it and nothing else. Bazel models a target as a file list, so the two
    only line up if every source lives directly in the target's own package.
    Enforcing that here, once, is what lets every downstream tool stop
    guessing which directory to run the engine in. Nested `.tf` files are
    child modules and belong in their own `terraform_module` target,
    referenced through a `module` block.

    Args:
        label: (Label) The `terraform_module` target, for error messages.
        srcs: (list[File]) The module's `.tf` sources.
        data: (list[File]) The module's data files, which may sit in
            subdirectories but not outside the module.

    Returns:
        (str) The module's staged directory (see `util.bzl`'s `staged_path`).
    """
    if not srcs:
        fail("terraform_module '{}' has no srcs — a Terraform module is a directory of .tf files.".format(label))

    root_dir = staged_dir(srcs[0])
    for src in srcs:
        if staged_dir(src) != root_dir:
            fail(
                ("terraform_module '{}' has srcs in more than one directory:\n" +
                 "  {}\n  {}\n" +
                 "A Terraform module is a single directory. Nested .tf files are " +
                 "child modules — give them their own terraform_module target and " +
                 "reference it with a `module` block.").format(
                    label,
                    staged_path(srcs[0]),
                    staged_path(src),
                ),
            )

        # The directory also has to be the target's own package, otherwise the
        # `module` block source paths a user writes (relative to the directory
        # holding the .tf files) wouldn't line up with the Bazel target graph
        # that supplies them. `File.owner` names the producing target exactly,
        # so no path-prefix guesswork is involved.
        owner = src.owner
        if owner.package != label.package or owner.workspace_name != label.workspace_name:
            fail(
                ("terraform_module '{}' has src '{}', which belongs to package '{}'.\n" +
                 "Declare the module in a BUILD file in that package instead.").format(
                    label,
                    staged_path(src),
                    owner.package,
                ),
            )

    # Anything outside the module directory can't be named by a relative path
    # from it, so it would silently never reach the built module — and a
    # missing `.tftest.hcl` fixture makes `terraform test` pass having read
    # nothing. Reject it here rather than let it vanish.
    root_prefix = root_dir + "/" if root_dir else ""
    for f in data:
        if not staged_path(f).startswith(root_prefix):
            fail(
                ("terraform_module '{}' has data file '{}' outside its module " +
                 "directory '{}'. Move it into the module, or expose it through a " +
                 "child `terraform_module`.").format(label, staged_path(f), root_dir),
            )

    return root_dir

def _terraform_module_impl(ctx):
    root_dir = _module_root_dir(ctx.label, ctx.files.srcs, ctx.files.data)

    module_deps = []
    provider_infos = []
    provider_sources = {}
    provider_group = None
    standalone_providers = []
    external_modules = []

    for dep in ctx.attr.deps:
        # A dependency hub carries both a provider group and a module group;
        # the two halves are read independently.
        grouped = False
        if TerraformProviderGroupInfo in dep:
            if provider_group != None:
                fail("terraform_module '{}' has more than one provider group in deps (a dependency hub counts as one). Only one is allowed.".format(ctx.label))
            provider_group = dep[TerraformProviderGroupInfo]
            for provider_info in provider_group.providers:
                provider_infos.append(provider_info)
                provider_sources[provider_info.source] = True
            grouped = True
        if TerraformModuleGroupInfo in dep:
            for mod_info in dep[TerraformModuleGroupInfo].modules:
                external_modules.append(mod_info)
            grouped = True
        if grouped:
            continue
        if TerraformProviderInfo in dep:
            standalone_providers.append(dep[TerraformProviderInfo])
        elif TerraformExternalModuleInfo in dep:
            external_modules.append(dep[TerraformExternalModuleInfo])
        elif TerraformInfo in dep:
            module_deps.append(dep[TerraformInfo])

    for provider_info in standalone_providers:
        if provider_group != None and provider_info.source not in provider_sources:
            fail("terraform_module '{}' has terraform_provider '{}' in deps that is not in the terraform_provider_group. All providers must be in the group when a group is present.".format(
                ctx.label,
                provider_info.source,
            ))
        if provider_info.source not in provider_sources:
            provider_infos.append(provider_info)
            provider_sources[provider_info.source] = True

    # A group carries the lock its providers were resolved from; it wins over
    # `lock` so the two cannot disagree.
    lock_file = provider_group.lock if provider_group != None and provider_group.lock else ctx.file.lock

    # The init aspect installs providers only alongside a lock file: the engine
    # refuses a provider directory it cannot check against one. Without this
    # the providers would be quietly left out and the module would fail later,
    # in validate, with advice to run `terraform init`.
    if provider_infos and not lock_file:
        fail(
            ("terraform_module '{}' depends on providers ({}) but has no `lock`.\n" +
             "Point `lock` at the module's .terraform.lock.hcl, or depend on a " +
             "terraform_provider_group, which carries one.").format(
                ctx.label,
                ", ".join(provider_sources.keys()),
            ),
        )

    provider_files_depsets = [p.files for p in provider_infos]

    all_module_files = [depset(ctx.files.srcs), depset(ctx.files.data)]
    if provider_files_depsets:
        all_module_files.extend(provider_files_depsets)
    for ext_mod in external_modules:
        all_module_files.append(ext_mod.files)

    return [
        DefaultInfo(
            files = depset(ctx.files.srcs),
            runfiles = ctx.runfiles(
                files = ctx.files.srcs + ctx.files.data,
                transitive_files = depset(transitive = all_module_files),
            ),
        ),
        TerraformInfo(
            srcs = depset(ctx.files.srcs),
            data = depset(ctx.files.data),
            root_dir = root_dir,
            disposable_state = ctx.attr.disposable_state,
            # Transitive: a shared module library whose members reference each
            # other only reaches the init action if the whole closure comes
            # along. The root module names `compute`; `compute`'s own `module`
            # block names `network`, and nothing in the root's BUILD file
            # mentions it.
            deps = depset(module_deps, transitive = [d.deps for d in module_deps]),
            providers = provider_infos,
            lock = lock_file,
            # Transitive for the same reason `deps` is, and the case is the
            # same one: the `module` block naming a registry module lives in
            # the shared library, so the library's BUILD file is where the
            # dep belongs. Flat, it would silently do nothing there and the
            # user would be pushed into declaring it on the root instead —
            # a site with no `module` block to justify it.
            external_modules = depset(
                external_modules,
                transitive = [d.external_modules for d in module_deps],
            ),
        ),
    ]

def _terraform_provider_impl(ctx):
    files_depsets = []
    for file_label in ctx.attr.files:
        if DefaultInfo in file_label:
            files_depsets.append(file_label[DefaultInfo].files)
    files_depset = depset(transitive = files_depsets) if files_depsets else depset()

    # A registry provider knows its platform: the archive was fetched for one.
    # A provider built in-repo is built for whatever platform this
    # configuration targets, so read that rather than assume one. The engine
    # looks the binary up under `<version>/<platform>/`, and a binary filed
    # under the wrong platform is simply not there.
    platform = ctx.attr.platform
    if not platform:
        platform = detect_platform(ctx, ctx.attr._platform_constraints)

    return [
        DefaultInfo(
            files = files_depset,
            runfiles = ctx.runfiles(files = files_depset.to_list()),
        ),
        TerraformProviderInfo(
            source = ctx.attr.source,
            version = ctx.attr.version,
            platform = platform,
            files = files_depset,
        ),
    ]

terraform_provider = rule(
    doc = """A provider built in this repository, for a `terraform_module`'s
`deps`. Registry providers come from a `deps` tag's hub instead.""",
    implementation = _terraform_provider_impl,
    attrs = {
        "files": attr.label_list(
            doc = "The provider binary and any files shipped with it.",
            allow_files = True,
            mandatory = True,
        ),
        "platform": attr.string(
            doc = """The platform, as `linux_amd64`. Leave it empty for a provider
            built here: it is taken from the configuration the provider is built
            in.""",
        ),
        "source": attr.string(
            doc = "The provider address as `required_providers` writes it, e.g. `hashicorp/null`.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The provider version, e.g. `3.2.4`.",
            mandatory = True,
        ),
        "_platform_constraints": attr.label_list(
            default = PLATFORM_CONSTRAINT_LABELS,
        ),
    },
    provides = [TerraformProviderInfo],
)

def _terraform_provider_group_impl(ctx):
    providers_list = []
    provider_files_depsets = []

    for dep in ctx.attr.deps:
        if TerraformProviderInfo in dep:
            provider_info = dep[TerraformProviderInfo]
            providers_list.append(provider_info)
            provider_files_depsets.append(provider_info.files)
        else:
            fail("terraform_provider_group '{}' has a dep '{}' that is not a terraform_provider".format(
                ctx.label,
                dep.label,
            ))

    all_files = depset(transitive = provider_files_depsets) if provider_files_depsets else depset()

    return [
        DefaultInfo(
            files = all_files,
            runfiles = ctx.runfiles(
                files = [ctx.file.lock] if ctx.file.lock else [],
                transitive_files = all_files,
            ),
        ),
        TerraformProviderGroupInfo(
            providers = providers_list,
            lock = ctx.file.lock,
        ),
    ]

terraform_provider_group = rule(
    doc = "Defines a group of Terraform providers with their lock file. This ensures all providers are from the same lock file.",
    implementation = _terraform_provider_group_impl,
    attrs = {
        "deps": attr.label_list(
            doc = "List of terraform_provider targets that belong to this group.",
            providers = [TerraformProviderInfo],
            mandatory = True,
        ),
        "lock": attr.label(
            doc = "The .terraform.lock.hcl file for this provider group.",
            allow_single_file = [".terraform.lock.hcl"],
            mandatory = True,
        ),
    },
    provides = [TerraformProviderGroupInfo],
)

def make_module_rule(engine):
    """The `<engine>_module` rule: one directory of configuration files.

    Args:
        engine: (struct) The `engine_config`. Its `source_extensions` are
            the only files `srcs` accepts.

    Returns:
        (rule) The module rule, providing `TerraformInfo`.
    """
    extensions = ", ".join(["`{}`".format(ext) for ext in engine.source_extensions])
    return rule(
        doc = "One directory of {} configuration: a root module, or a child that another module's `module` block names.".format(engine.name),
        implementation = _terraform_module_impl,
        attrs = {
            "data": attr.label_list(
                doc = "Additional files or targets that should be available at runtime.",
                allow_files = True,
            ),
            "deps": attr.label_list(
                doc = """What the configuration references: child `terraform_module`s
                for its local `module` blocks, a dependency hub (`@<name>` from a
                `deps` tag, or its `//:providers` / `//:modules` halves) or single
                `@<name>//<namespace>_<name>` providers, and `terraform_provider`
                or `terraform_external_module` targets. The `module` block names a
                child's path; `deps` says which target supplies it. A child in a
                package under this one lands at its relative path; any other is
                matched to the block whose `source` ends with its package name.""",
                providers = [
                    [TerraformInfo],
                    [TerraformProviderInfo],
                    [TerraformProviderGroupInfo],
                    [TerraformExternalModuleInfo],
                    [TerraformModuleGroupInfo],
                ],
            ),
            # True is the default because a run reads nothing a previous run
            # left behind and writes nothing outside its temp copy; the one
            # opt-in to persistence lives under bazel-out, never in the source
            # tree, so state can neither leak into a `data` glob nor silently
            # steer the next run. The runner implements both (engine/runner).
            "disposable_state": attr.bool(
                default = True,
                doc = """Whether local state may go with the run, for a module with
                no `backend` or `cloud` block. True, the default: the engine keeps
                state in the run's temp directory, which is deleted afterwards; a
                run that wrote state is kept and its path printed. False: state is
                kept under `bazel-out/rules_terraform/` across runs, until
                `bazel clean`. An error when the module declares a backend.""",
            ),
            "lock": attr.label(
                doc = """The module's `.terraform.lock.hcl`. Not needed when `deps`
                names a dependency hub, which carries its lock.""",
                allow_single_file = [".terraform.lock.hcl"],
            ),
            "srcs": attr.label_list(
                doc = """The configuration files of this module: {}, all directly in
                this target's package. A nested directory of configuration is its
                own module target, named by a `module` block.""".format(extensions),
                allow_files = engine.source_extensions,
            ),
        },
        provides = [TerraformInfo],
    )

RUNNER_MODES = ["run", "test", "plan"]

def build_runner(ctx, toolchain_type, *, mode):
    """Shared implementation for the `*_binary`, `*_test` and `*_plan_test` rules.

    Args:
        ctx: (ctx) The rule context.
        toolchain_type: (str) Fully-qualified label string of the
            toolchain type the rule should resolve.
        mode: (str) One of `RUNNER_MODES`. `run` passes argv through to
            the engine (`terraform_binary`). `test` runs the engine's
            native test framework and reports through Bazel's test
            protocol (`terraform_test`). `plan` initializes, plans, and
            keeps the plan as an undeclared test output
            (`terraform_plan_test`). The runner reads it from
            `RULES_TERRAFORM_MODE`.

    Returns:
        (list[Provider]) `DefaultInfo` (executable + runfiles) and
        either `RunEnvironmentInfo` or `testing.TestEnvironment`.
    """
    if mode not in RUNNER_MODES:
        fail("build_runner: unknown mode {}".format(repr(mode)))
    test_mode = mode != "run"
    toolchain = ctx.toolchains[toolchain_type]
    root_info = ctx.attr.root[TerraformInfo]

    # `terraform_init_aspect` already assembled the directory the engine runs
    # in — sources, local child modules, lock file and `.terraform/`. The
    # runner copies that one tree and works inside it, so nothing here has to
    # describe the module's layout a second time.
    module_directory = module_dir(ctx.attr.root)
    if not module_directory:
        fail("{}: terraform_init_aspect produced no module directory for '{}'".format(ctx.label, ctx.attr.root.label))

    # The module's directory under `bazel-out`, where what the native CLI
    # would keep in the module directory between runs lives instead. Named
    # after the root module, not this target, so every binary over one module
    # shares it; and directly under the output root rather than `ctx.bin_dir`,
    # so it does not fork with the configuration. Execroot-relative: the
    # runner finds the execroot from where the args file resolves to.
    root_label = ctx.attr.root.label
    output_root = ctx.bin_dir.path.split("/")[0]
    local_dir = "/".join([p for p in [output_root, "rules_terraform", root_label.workspace_root, root_label.package, root_label.name] if p])

    args_file = ctx.actions.declare_file("{}.terraform_args.json".format(ctx.label.name))
    args_data = {
        "args_file_path": args_file.path,
        "disposable_state": root_info.disposable_state,
        "local_dir": local_dir,
        "module_dir_rlocationpath": rlocationpath(module_directory, ctx.workspace_name),
        "terraform_rlocationpath": rlocationpath(toolchain.terraform, ctx.workspace_name),
    }
    env = engine_env(ctx)
    if env:
        args_data["env"] = env
    if test_mode and ctx.attr.env_inherit:
        args_data["env_inherit"] = ctx.attr.env_inherit
    if not test_mode and not root_label.workspace_root:
        # `init` under the binary installs into the checkout, at the root
        # module's package under BUILD_WORKSPACE_DIRECTORY. A root in another
        # repository has no such place, and the runner says so.
        args_data["module_package"] = root_label.package
    if mode == "plan":
        args_data["plan"] = {
            "args": ctx.attr.plan_args,
            "expect_no_changes": ctx.attr.expect_no_changes,
            "lock": ctx.attr.lock,
        }

    ctx.actions.write(
        output = args_file,
        content = json.encode_indent(args_data),
    )

    is_windows = ctx.executable._runner.basename.endswith(".exe")
    executable = ctx.actions.declare_file("{}{}".format(ctx.label.name, ".exe" if is_windows else ""))
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable._runner,
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = [args_file, module_directory],
        transitive_files = toolchain.all_files,
    )

    runner_env = {
        "RULES_TERRAFORM_ARGS_FILE": rlocationpath(args_file, ctx.workspace_name),
    }
    if test_mode:
        runner_env["RULES_TERRAFORM_MODE"] = mode

    providers = [
        DefaultInfo(
            runfiles = runfiles,
            executable = executable,
        ),
    ]
    if test_mode:
        providers.append(testing.TestEnvironment(runner_env, inherited_environment = ctx.attr.env_inherit))
    else:
        providers.append(RunEnvironmentInfo(environment = runner_env))
    return providers

RUNNER_ATTRS = dict(ENV_ATTRS, **{
    "root": attr.label(
        doc = "The terraform_module target that serves as the root module.",
        providers = [TerraformInfo],
        aspects = [terraform_init_aspect],
        mandatory = True,
    ),
    "_runner": attr.label(
        cfg = "exec",
        executable = True,
        default = Label("//engine/runner"),
    ),
})

TEST_RUNNER_ATTRS = dict(RUNNER_ATTRS, **TEST_ENV_ATTRS)

PLAN_TEST_ATTRS = dict(TEST_RUNNER_ATTRS, **{
    "expect_no_changes": attr.bool(
        default = False,
        doc = "Fail when the plan proposes any change.",
    ),
    "lock": attr.bool(
        default = False,
        doc = """Take the backend's state lock while planning. Off by default
        so a test never blocks, or is blocked by, an operator's apply.""",
    ),
    "plan_args": attr.string_list(
        doc = """Extra arguments for `plan`, such as `-var` and `-target`,
        after the ones the rule sets. Bazel's own `args` is ignored.""",
    ),
})

# The engine-bound `terraform_binary` / `terraform_test` rules are produced
# by `//engine:engine_factory.bzl` and re-exported through
# `//terraform:terraform_binary.bzl` / `//terraform:terraform_test.bzl`.

# External module rules (loaded by BUILD files that `module_repo.bzl` writes
# into generated repositories).

def _terraform_external_module_impl(ctx):
    all_files = depset(ctx.files.srcs)

    return [
        DefaultInfo(
            files = all_files,
            runfiles = ctx.runfiles(files = ctx.files.srcs),
        ),
        TerraformExternalModuleInfo(
            source = ctx.attr.source,
            subdir = ctx.attr.subdir,
            version = ctx.attr.version,
            files = all_files,
        ),
    ]

terraform_external_module = rule(
    doc = """A module whose files come from outside the workspace.

The `deps` tag declares one per registry or git module it resolves. Declare
one yourself, in the `build_file_content` of an `http_archive` or
`git_repository`, for a module the extension cannot fetch. `source` must
match the `module` block verbatim; list the target in the consuming
`terraform_module`'s `deps`.""",
    implementation = _terraform_external_module_impl,
    attrs = {
        "source": attr.string(
            doc = """The `source` string exactly as the `module` blocks write it.
            The module is installed under every block whose `source` matches.""",
            mandatory = True,
        ),
        "srcs": attr.label_list(
            doc = """Every file of the module's repository or archive, not only the
            module's own: templates and other data the configuration reads, and
            the siblings a `../` source inside it names.""",
            allow_files = True,
        ),
        "subdir": attr.string(
            doc = """The module's directory inside `srcs`: the `//subdir` of the
            source, empty for the archive root.""",
        ),
        "version": attr.string(
            doc = """The module's version, for a registry module. Leave it empty
            for a git or other source: the manifest only accepts a semantic
            version.""",
        ),
    },
    provides = [TerraformExternalModuleInfo],
)

def _terraform_module_group_impl(ctx):
    modules = []
    all_files_depsets = []

    for dep in ctx.attr.deps:
        if TerraformExternalModuleInfo in dep:
            modules.append(dep[TerraformExternalModuleInfo])
            all_files_depsets.append(dep[TerraformExternalModuleInfo].files)
        else:
            fail("terraform_module_group '{}' dep '{}' does not provide TerraformExternalModuleInfo".format(
                ctx.label,
                dep.label,
            ))

    all_files = depset(transitive = all_files_depsets) if all_files_depsets else depset()

    return [
        DefaultInfo(
            files = all_files,
            runfiles = ctx.runfiles(transitive_files = all_files),
        ),
        TerraformModuleGroupInfo(
            modules = modules,
        ),
    ]

terraform_module_group = rule(
    doc = "Aggregates external Terraform modules into a single group.",
    implementation = _terraform_module_group_impl,
    attrs = {
        "deps": attr.label_list(
            doc = "List of terraform_external_module targets.",
            providers = [TerraformExternalModuleInfo],
            mandatory = True,
        ),
    },
    provides = [TerraformModuleGroupInfo],
)

def _terraform_dependency_group_impl(ctx):
    providers_list = [p[TerraformProviderInfo] for p in ctx.attr.providers]
    modules_list = [m[TerraformExternalModuleInfo] for m in ctx.attr.modules]
    all_files = depset(transitive = [p.files for p in providers_list] + [m.files for m in modules_list])

    result = [
        DefaultInfo(
            files = all_files,
            runfiles = ctx.runfiles(
                files = [ctx.file.lock] if ctx.file.lock else [],
                transitive_files = all_files,
            ),
        ),
        TerraformModuleGroupInfo(modules = modules_list),
    ]

    # Providers only mean something alongside the lock they were resolved
    # from; a hub built from `roots` alone has neither.
    if ctx.file.lock:
        result.append(TerraformProviderGroupInfo(providers = providers_list, lock = ctx.file.lock))
    elif providers_list:
        fail("terraform_dependency_group '{}' has providers but no lock".format(ctx.label))
    return result

terraform_dependency_group = rule(
    doc = """Everything one `deps` tag resolved: the providers its lock pins,
that lock, and the registry modules its `roots` name. Generated at the root
of every dependency hub; a `terraform_module` that depends on it needs no
`lock` of its own.""",
    implementation = _terraform_dependency_group_impl,
    attrs = {
        "lock": attr.label(
            doc = "The `.terraform.lock.hcl` the providers were resolved from.",
            allow_single_file = [".terraform.lock.hcl"],
        ),
        "modules": attr.label_list(
            doc = "`terraform_external_module` targets.",
            providers = [TerraformExternalModuleInfo],
        ),
        "providers": attr.label_list(
            doc = "`terraform_provider` targets (or aliases to them).",
            providers = [TerraformProviderInfo],
        ),
    },
    provides = [TerraformModuleGroupInfo],
)
