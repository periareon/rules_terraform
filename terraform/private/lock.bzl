"""Rules that keep `.terraform.lock.hcl` in sync with the .tf source
files it covers, and regenerate it for every platform.

Each rule symlinks a purpose-built Go binary as its executable and passes
inputs through a `ctx.actions.args()` multiline param file. The rlocationpath
of that file is delivered to the tool via an environment variable
(`RULES_TERRAFORM_LOCK{CHECK,REF}_ARGS_FILE`). Each tool reads the file,
prepends its lines to `os.Args`, and then does its own normal flag parsing.

Path values in the args file take two forms:

* `${BUILD_WORKSPACE_DIRECTORY}/<path>` for `bazel run` targets that write
  back to the source tree — the env var is expanded before the tool runs.
* Bare runfiles rlocationpaths for `bazel test` targets. Each tool resolves
  them via `runfiles.Rlocation` at startup so tests work on Windows where
  the runfiles symlink tree isn't materialized (`.bazelrc` sets
  `--nobuild_runfile_links`).

Rules:

* `terraform_providers_lock` / `tofu_providers_lock` — `bazel run`
  updater for `.terraform.lock.hcl`. Runs real `<engine> providers lock
  -platform=<all>` under the toolchain-fetched binary.
* `terraform_providers_lock_test` — network-free presence check for
  `.terraform.lock.hcl` vs `required_providers { ... }` blocks.

External Terraform registry modules are resolved live by the
`terraform.modules(...)` / `tofu.modules(...)` bzlmod extensions
themselves — no lock file, no `bazel run` updater. See
`//terraform/private:modules_extension.bzl`.
"""

load(":providers.bzl", "TerraformInfo")
load(":util.bzl", "common_ancestor", "rlocationpath", "tree_relative")

# Default multi-platform set used when a `terraform_providers_lock` target
# doesn't specify `platforms`. Matches the platforms the extension fetches
# providers for so the golden covers everyone who might build the module.
_DEFAULT_LOCK_PLATFORMS = [
    "linux_amd64",
    "linux_arm64",
    "darwin_amd64",
    "darwin_arm64",
    "windows_amd64",
]

visibility(["//terraform/...", "//tests/...", "//tofu/..."])

def _collect_tf_srcs(target_info):
    """Return a de-duplicated list of source .tf files reachable from target_info."""
    files = []
    seen = {}
    stack = [target_info]
    for _ in range(1000):  # bounded to avoid runaway iteration
        if not stack:
            break
        info = stack.pop()
        for src in info.srcs.to_list():
            if not src.is_source:
                continue
            if src.path in seen:
                continue
            seen[src.path] = True
            files.append(src)
        for dep in info.deps.to_list():
            stack.append(dep)
    return files

def _write_args_file(ctx, args, name):
    args.set_param_file_format("multiline")
    args_file = ctx.actions.declare_file("{}.{}.args".format(ctx.label.name, name))
    ctx.actions.write(output = args_file, content = args)
    return args_file

def _symlink_executable(ctx, tool):
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = tool,
        is_executable = True,
    )
    return executable

def _build_lockcheck(ctx, tidy_hint):
    target_info = ctx.attr.target[TerraformInfo]
    srcs = _collect_tf_srcs(target_info)
    lock_file = ctx.file.lock

    args = ctx.actions.args()
    args.add("-lock=" + rlocationpath(lock_file, ctx.workspace_name))
    args.add("-tidy-hint=" + tidy_hint)
    for src in srcs:
        args.add("-src=" + rlocationpath(src, ctx.workspace_name))

    args_file = _write_args_file(ctx, args, "lockcheck")
    executable = _symlink_executable(ctx, ctx.executable._lockcheck)

    runfiles = ctx.runfiles(files = [ctx.executable._lockcheck, args_file, lock_file] + srcs)
    runfiles = runfiles.merge(ctx.attr._lockcheck[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        testing.TestEnvironment({
            "RULES_TERRAFORM_LOCKCHECK_ARGS_FILE": rlocationpath(args_file, ctx.workspace_name),
        }),
    ]

def _terraform_providers_lock_test_impl(ctx):
    return _build_lockcheck(ctx, "bazel run the terraform_providers_lock / tofu_providers_lock target for this module to regenerate the lock")

terraform_providers_lock_test = rule(
    doc = """Fails the test if `.terraform.lock.hcl` doesn't cover every provider
    declared in `terraform { required_providers { ... } }` blocks reachable
    from `target` (and vice versa). Network-free presence check.""",
    implementation = _terraform_providers_lock_test_impl,
    attrs = {
        "lock": attr.label(
            doc = "The .terraform.lock.hcl file being verified.",
            allow_single_file = [".terraform.lock.hcl"],
            mandatory = True,
        ),
        "target": attr.label(
            doc = "The terraform_module whose transitive sources are being checked.",
            providers = [TerraformInfo],
            mandatory = True,
        ),
        "_lockcheck": attr.label(
            executable = True,
            cfg = "target",
            default = Label("//terraform/private/lockcheck"),
        ),
    },
    test = True,
)

def build_providers_lock(ctx, toolchain_type):
    """Shared `terraform_providers_lock` / `tofu_providers_lock` rule impl.

    Args:
        ctx: (ctx) The rule context.
        toolchain_type: (str) Fully-qualified label string of the
            toolchain type whose binary regenerates the lock file.

    Returns:
        (list[Provider]) `DefaultInfo` (executable + runfiles) and a
        `RunEnvironmentInfo` pointing at the args file.
    """
    toolchain = ctx.toolchains[toolchain_type]
    target_info = ctx.attr.target[TerraformInfo]

    # The engine's `init` has to find every local child module, so the temp
    # dir is seeded with the whole local module tree, not just the root's own
    # files: the root plus every transitive `terraform_module` dep, at their
    # positions in the source tree. Only main-repo source files — external and
    # generated files have no position in `$BUILD_WORKSPACE_DIRECTORY`.
    local_deps = target_info.deps.to_list()
    srcs = []
    seen = {}
    for info in [target_info] + local_deps:
        for src in info.srcs.to_list():
            if not src.is_source or src.short_path.startswith("../"):
                continue
            if src.short_path in seen:
                continue
            seen[src.short_path] = True
            srcs.append(src)
    if not srcs:
        fail("terraform_providers_lock requires target with source .tf files under the workspace root")

    output_rel = ctx.attr.output
    if ctx.label.package:
        output_rel = "{}/{}".format(ctx.label.package, output_rel)

    platforms = ctx.attr.platforms or _DEFAULT_LOCK_PLATFORMS

    # The tree is rooted where the init aspect roots it: the deepest directory
    # the root module and its deps share, so a `../../../modules/network`
    # source has somewhere to climb into. The engine runs in `workdir` inside
    # it. For a root whose deps all nest beneath it, that is the root's own
    # package and `workdir` is empty.
    tree_root = common_ancestor([target_info.root_dir] + [d.root_dir for d in local_deps])
    workdir = tree_relative(target_info.root_dir, tree_root)

    args = ctx.actions.args()
    args.add("-engine=" + rlocationpath(toolchain.terraform, ctx.workspace_name))
    args.add("-out=${BUILD_WORKSPACE_DIRECTORY}/" + output_rel)
    args.add("-root=${BUILD_WORKSPACE_DIRECTORY}/" + tree_root)
    if workdir:
        args.add("-workdir=" + workdir)
    for src in srcs:
        args.add("-src=${BUILD_WORKSPACE_DIRECTORY}/" + src.short_path)
    for platform in platforms:
        args.add("-platform=" + platform)

    args_file = _write_args_file(ctx, args, "lockref")
    executable = _symlink_executable(ctx, ctx.executable._lockref)

    runfiles = ctx.runfiles(files = [ctx.executable._lockref, args_file] + srcs)
    runfiles = runfiles.merge(ctx.attr._lockref[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.runfiles(transitive_files = toolchain.all_files))

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(environment = {
            "RULES_TERRAFORM_LOCKREF_ARGS_FILE": rlocationpath(args_file, ctx.workspace_name),
        }),
    ]

PROVIDERS_LOCK_ATTRS = {
    "output": attr.string(
        doc = """Where to write the multi-platform `.terraform.lock.hcl`,
        relative to this BUILD file's package. Diff-test companions
        should point `golden = "<same-path>"`.""",
        mandatory = True,
    ),
    "platforms": attr.string_list(
        doc = "os_arch platforms to record hashes for. Defaults to the common set.",
    ),
    "target": attr.label(
        doc = """The terraform_module whose .tf sources drive the lock
        resolution. Its local child modules come along, so
        `required_providers` blocks anywhere in the tree count.""",
        providers = [TerraformInfo],
        mandatory = True,
    ),
    "_lockref": attr.label(
        executable = True,
        cfg = "exec",
        default = Label("//terraform/private/lockref"),
    ),
}

# `terraform_providers_lock` / `tofu_providers_lock` are produced by
# the shared factory (`//terraform/private:engine_factory.bzl`) so both
# engines share the same rule body. Re-exported from
# `//terraform:terraform_providers_lock.bzl` and
# `//tofu:tofu_providers_lock.bzl`.
