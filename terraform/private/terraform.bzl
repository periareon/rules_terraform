"""Bazel terraform rules.

The `RUNNER_ATTRS` / `build_runner` helpers here are consumed by `//tofu`
so the same rule bodies power both engines.
"""

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

# Extension-generated hub BUILD files under external repos load
# `terraform_provider` / `terraform_module_group` / `terraform_external_module`
# from here, so the file must be publicly loadable.
visibility("public")

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
            allow_ephemeral_state = ctx.attr.allow_ephemeral_state,
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
    doc = "Defines a Terraform provider that can be used as a dependency in terraform_module targets.",
    implementation = _terraform_provider_impl,
    attrs = {
        "files": attr.label_list(
            doc = "The provider binary files.",
            allow_files = True,
            mandatory = True,
        ),
        "platform": attr.string(
            doc = """Platform string (e.g., 'linux_amd64', 'darwin_arm64').
            Set by the generated repositories for registry providers. Leave it
            empty for a provider built in this repo: it is then taken from the
            target platform of the configuration the provider is built in.""",
        ),
        "source": attr.string(
            doc = "Provider source (e.g., 'hashicorp/null').",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "Provider version (e.g., '3.2.4').",
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

terraform_module = rule(
    doc = "Defines a Terraform module that can be used as a dependency in other Terraform targets.",
    implementation = _terraform_module_impl,
    attrs = {
        "allow_ephemeral_state": attr.bool(
            default = False,
            doc = """Permit `bazel run` of `apply`, `destroy` and the other
            state-writing commands against a module with no `backend` or
            `cloud` block.

            Without a backend the engine keeps state in its working directory,
            which under Bazel is a staged copy that exists for one run. The
            runner therefore refuses those commands by default, naming the fix.
            With this set, state is kept under `bazel-out` between runs: private
            to the machine, forked per build configuration, and deleted by
            `bazel clean`. Set it only where losing the state is harmless: demos,
            sandboxes, or bootstrapping the bucket that will hold real state.
            Ignored when a backend is declared; `plan` and the read-only
            commands are never gated.""",
        ),
        "data": attr.label_list(
            doc = "Additional files or targets that should be available at runtime.",
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = """Other terraform_module targets, a dependency hub (`@<name>` from a
            `deps` tag, or its `//:providers` / `//:modules` halves), individual
            `@<name>//<namespace>_<name>` providers, `terraform_provider`, or
            `terraform_external_module` targets this module depends on.

            A `terraform_module` dep is the Bazel half of a `module` block, the
            way a `py_library` dep is the Bazel half of an `import`: the `.tf`
            file names the path, `deps` says which target supplies it. A dep
            whose package already nests under this module's directory lands at
            that relative path; anything else is matched to a `module` block
            whose `source` ends with the dep's package name.""",
            providers = [
                [TerraformInfo],
                [TerraformProviderInfo],
                [TerraformProviderGroupInfo],
                [TerraformExternalModuleInfo],
                [TerraformModuleGroupInfo],
            ],
        ),
        "lock": attr.label(
            doc = "An optional `.terraform.lock.hcl` file.",
            allow_single_file = [".terraform.lock.hcl"],
        ),
        "srcs": attr.label_list(
            doc = """Terraform source files that make up this module: `.tf`,
            `.tf.json`, and OpenTofu's `.tofu` / `.tofu.json`.

            All of them must live directly in this target's package — a Terraform
            module is a single directory. Put nested .tf files in their own
            `terraform_module` and reference it with a `module` block.""",
            allow_files = [".tf", ".tf.json", ".tofu", ".tofu.json"],
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

    args_data = {
        "allow_ephemeral_state": root_info.allow_ephemeral_state,
        "module_dir_rlocationpath": rlocationpath(module_directory, ctx.workspace_name),
        # Where local state lives between runs when `allow_ephemeral_state`
        # is set: a per-target directory under bazel-out, reached from
        # `BUILD_WORKSPACE_DIRECTORY` through the convenience symlink. Under
        # bazel-out on purpose — it should go when the build outputs go.
        "state_dir": "{}/{}/{}.state".format(ctx.bin_dir.path, ctx.label.package, ctx.label.name) if ctx.label.package else "{}/{}.state".format(ctx.bin_dir.path, ctx.label.name),
        "terraform_rlocationpath": rlocationpath(toolchain.terraform, ctx.workspace_name),
    }
    if mode == "plan":
        args_data["plan"] = {
            "args": ctx.attr.plan_args,
            "expect_no_changes": ctx.attr.expect_no_changes,
            "lock": ctx.attr.lock,
        }

    args_file = ctx.actions.declare_file("{}.terraform_args.json".format(ctx.label.name))
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

    env = {
        "RULES_TERRAFORM_ARGS_FILE": rlocationpath(args_file, ctx.workspace_name),
    }
    if test_mode:
        env["RULES_TERRAFORM_MODE"] = mode

    providers = [
        DefaultInfo(
            runfiles = runfiles,
            executable = executable,
        ),
    ]
    if test_mode:
        providers.append(testing.TestEnvironment(env))
    else:
        providers.append(RunEnvironmentInfo(environment = env))
    return providers

RUNNER_ATTRS = {
    "root": attr.label(
        doc = "The terraform_module target that serves as the root module.",
        providers = [TerraformInfo],
        aspects = [terraform_init_aspect],
        mandatory = True,
    ),
    "_runner": attr.label(
        cfg = "exec",
        executable = True,
        default = Label("//terraform/private/runner"),
    ),
}

PLAN_TEST_ATTRS = dict(RUNNER_ATTRS, **{
    "expect_no_changes": attr.bool(
        default = False,
        doc = """Fail when the plan proposes any change. Off by default:
        a plan that applies cleanly is the usual thing to check, and
        whether it is empty depends on what has been applied.""",
    ),
    "lock": attr.bool(
        default = False,
        doc = """Take the backend's state lock while planning. Off by
        default so a test cannot block on, or be blocked by, an operator's
        apply; a plan does not write state.""",
    ),
    "plan_args": attr.string_list(
        doc = """Extra arguments for `plan`, after the ones the rule
        sets (`-input=false`, `-detailed-exitcode`, `-out`, and
        `-lock=false` unless `lock` is set). `-var` and `-target` go
        here. Named `plan_args` because `args` is Bazel's own test
        attribute, which this rule ignores.""",
    ),
})

# The engine-bound `terraform_binary` / `terraform_test` rules are produced
# by `//terraform/private:engine_factory.bzl` and re-exported through
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
            version = ctx.attr.version,
            files = all_files,
        ),
    ]

terraform_external_module = rule(
    doc = """A module whose files come from outside the workspace.

The `terraform.modules(...)` extension declares one of these per registry
module it resolves. Declare one yourself, in the `build_file_content` of an
`http_archive` or `git_repository`, to supply a module the extension cannot
fetch: a module hosted somewhere other than a public registry, or a plain
`git::` / `https://` source. Match `source` to the `module` block verbatim and
list the target in the consuming `terraform_module`'s `deps`.""",
    implementation = _terraform_external_module_impl,
    attrs = {
        "source": attr.string(
            doc = """The `source` string exactly as `module` blocks write it:
            a registry address (`terraform-aws-modules/vpc/aws`, with any
            `//subdir`), or any other address Terraform accepts, such as
            `git::https://…?ref=v1.2.0`. The init aspect installs this
            module under every `module` block whose `source` matches.""",
            mandatory = True,
        ),
        "srcs": attr.label_list(
            doc = "Module source files.",
            allow_files = True,
        ),
        "version": attr.string(
            doc = """The module's version, for a registry module. The init
            aspect records it in the module manifest and uses it to pick
            between two versions of one module. Leave it empty for a git or
            other non-registry source: Terraform rejects a manifest entry
            whose version is not a semantic version, and a commit id or tag
            name is not one.""",
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
