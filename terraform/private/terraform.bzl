"""Bazel terraform rules.

The `RUNNER_ATTRS` / `build_runner` helpers here are consumed by `//opentofu`
so the same rule bodies power both engines.
"""

load(":init.bzl", "terraform_init_aspect")
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
    providers_dict = {}
    provider_files_depsets = []
    provider_group = None
    provider_group_lock = None
    standalone_providers = []
    external_modules = []

    for dep in ctx.attr.deps:
        if TerraformProviderGroupInfo in dep:
            if provider_group != None:
                fail("terraform_module '{}' has more than one terraform_provider_group in deps. Only one provider group is allowed.".format(ctx.label))
            provider_group = dep[TerraformProviderGroupInfo]
            provider_group_lock = provider_group.lock
            for provider_info in provider_group.providers:
                providers_dict[provider_info.source] = provider_info.repository_label
                provider_files_depsets.append(provider_info.files)
        elif TerraformProviderInfo in dep:
            standalone_providers.append(dep[TerraformProviderInfo])
        elif TerraformModuleGroupInfo in dep:
            for mod_info in dep[TerraformModuleGroupInfo].modules:
                external_modules.append(mod_info)
        elif TerraformExternalModuleInfo in dep:
            external_modules.append(dep[TerraformExternalModuleInfo])
        elif TerraformInfo in dep:
            module_deps.append(dep[TerraformInfo])

    if provider_group != None and standalone_providers:
        group_provider_sources = [p.source for p in provider_group.providers]
        for standalone_provider in standalone_providers:
            provider_info = standalone_provider[TerraformProviderInfo]
            if provider_info.source not in group_provider_sources:
                fail("terraform_module '{}' has terraform_provider '{}' in deps that is not in the terraform_provider_group. All providers must be in the group when a group is present.".format(
                    ctx.label,
                    provider_info.source,
                ))
            if provider_info.source not in providers_dict:
                providers_dict[provider_info.source] = provider_info.repository_label
                provider_files_depsets.append(provider_info.files)
    elif standalone_providers:
        for provider_info in standalone_providers:
            providers_dict[provider_info.source] = provider_info.repository_label
            provider_files_depsets.append(provider_info.files)

    lock_file = provider_group_lock if provider_group_lock else ctx.file.lock

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
            # Transitive: a shared module library whose members reference each
            # other only reaches the init action if the whole closure comes
            # along. The root module names `compute`; `compute`'s own `module`
            # block names `network`, and nothing in the root's BUILD file
            # mentions it.
            deps = depset(module_deps, transitive = [d.deps for d in module_deps]),
            providers = providers_dict,
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

    # `terraform_provider` is instantiated inside the provider repository
    # generated by `terraform_provider_repository`, so `ctx.label` already
    # names that repo.
    repository_label = ctx.label

    return [
        DefaultInfo(
            files = files_depset,
            runfiles = ctx.runfiles(files = files_depset.to_list()),
        ),
        TerraformProviderInfo(
            source = ctx.attr.source,
            version = ctx.attr.version,
            platform = ctx.attr.platform,
            files = files_depset,
            repository_label = repository_label,
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
            doc = "Platform string (e.g., 'linux_amd64', 'darwin_arm64'). If omitted, auto-detected at build time.",
        ),
        "source": attr.string(
            doc = "Provider source (e.g., 'hashicorp/null').",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "Provider version (e.g., '3.2.4').",
            mandatory = True,
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
        "data": attr.label_list(
            doc = "Additional files or targets that should be available at runtime.",
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = """Other terraform_module, terraform_provider, terraform_provider_group,
            terraform_external_module, or terraform_module_group targets that this module depends on.

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
            doc = """Terraform source files (.tf) that make up this module.

            All of them must live directly in this target's package — a Terraform
            module is a single directory. Put nested .tf files in their own
            `terraform_module` and reference it with a `module` block.""",
            allow_files = [".tf"],
        ),
    },
    provides = [TerraformInfo],
)

def build_runner(ctx, toolchain_type, *, test_mode):
    """Shared implementation for `*_binary` and `*_test` runner rules.

    Args:
        ctx: (ctx) The rule context.
        toolchain_type: (str) Fully-qualified label string of the
            toolchain type the rule should resolve.
        test_mode: (bool) True for the `_test` variant (returns
            `testing.TestEnvironment` and hard-codes the `test`
            subcommand via `RULES_TERRAFORM_MODE=test`), False for
            `_binary`.

    Returns:
        (list[Provider]) `DefaultInfo` (executable + runfiles) and
        either `RunEnvironmentInfo` or `testing.TestEnvironment`.
    """
    toolchain = ctx.toolchains[toolchain_type]

    # `terraform_init_aspect` already assembled the directory the engine runs
    # in — sources, local child modules, lock file and `.terraform/`. The
    # runner copies that one tree and works inside it, so nothing here has to
    # describe the module's layout a second time.
    module_directory = module_dir(ctx.attr.root)
    if not module_directory:
        fail("{}: terraform_init_aspect produced no module directory for '{}'".format(ctx.label, ctx.attr.root.label))

    args_data = {
        "module_dir_rlocationpath": rlocationpath(module_directory, ctx.workspace_name),
        "terraform_rlocationpath": rlocationpath(toolchain.terraform, ctx.workspace_name),
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
        env["RULES_TERRAFORM_MODE"] = "test"

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
            key = ctx.attr.key,
            source = ctx.attr.source,
            version = ctx.attr.version,
            subdir = ctx.attr.subdir,
            files = all_files,
        ),
    ]

terraform_external_module = rule(
    doc = "An external Terraform module downloaded from a registry. Created by terraform_module_repository.",
    implementation = _terraform_external_module_impl,
    attrs = {
        "key": attr.string(
            doc = "Module key matching the key in terraform_modules.lock.json.",
            mandatory = True,
        ),
        "source": attr.string(
            doc = "Registry source (e.g., 'terraform-aws-modules/vpc/aws').",
            mandatory = True,
        ),
        "srcs": attr.label_list(
            doc = "Module source files.",
            allow_files = True,
        ),
        "subdir": attr.string(
            doc = "Subdirectory within the archive.",
            default = "",
        ),
        "version": attr.string(
            doc = "Module version.",
            mandatory = True,
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
