"""Rules that keep `.terraform.lock.hcl` in sync with the .tf source
files it covers, and regenerate the multi-platform golden.

Each rule symlinks a purpose-built Go binary as its executable and passes
inputs through a `ctx.actions.args()` multiline param file. The rlocationpath
of that file is delivered to the tool via an environment variable
(`RULES_TERRAFORM_LOCK{CHECK,DIFF,REF}_ARGS_FILE`). Each tool reads the file,
prepends its lines to `os.Args`, and then does its own normal flag parsing.

Path values in the args file take two forms:

* `${BUILD_WORKSPACE_DIRECTORY}/<path>` for `bazel run` targets that write
  back to the source tree — the env var is expanded before the tool runs.
* Bare runfiles rlocationpaths for `bazel test` targets. Each tool resolves
  them via `runfiles.Rlocation` at startup so tests work on Windows where
  the runfiles symlink tree isn't materialized (`.bazelrc` sets
  `--nobuild_runfile_links`).

Rules:

* `terraform_providers_lock` / `opentofu_providers_lock` — `bazel run`
  updater for `.terraform.lock.hcl`. Runs real `<engine> providers lock
  -platform=<all>` under the toolchain-fetched binary.
* `terraform_providers_lock_test` — network-free presence check for
  `.terraform.lock.hcl` vs `required_providers { ... }` blocks.
* `terraform_lock_diff_test` — structural diff of the aspect-generated
  `.terraform.lock.hcl` against a checked-in golden from real init.

External Terraform registry modules are resolved live by the
`terraform.modules(...)` / `opentofu.modules(...)` bzlmod extensions
themselves — no lock file, no `bazel run` updater. See
`//terraform/private:modules_extension.bzl`.
"""

load(":init.bzl", "terraform_init_aspect")
load(":providers.bzl", "TerraformInfo")
load(":util.bzl", "rlocationpath")

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

visibility(["//opentofu/...", "//terraform/...", "//tests/..."])

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
    return _build_lockcheck(ctx, "regenerate with 'terraform providers lock'")

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

def _terraform_lock_diff_test_impl(ctx):
    target = ctx.attr.target
    output_groups = target[OutputGroupInfo] if OutputGroupInfo in target else None
    aspect_dir = None
    if output_groups and hasattr(output_groups, "terraform_init"):
        entries = output_groups.terraform_init.to_list()
        if entries:
            aspect_dir = entries[0]
    if not aspect_dir:
        fail("terraform_init_aspect must run on `target`; got no output.")

    # The aspect's `.terraform.lock.hcl` lives inside the declared directory.
    # We compose the runfiles path by joining the directory's rlocation with
    # the well-known filename inside it.
    aspect_lock_rloc = "{}/.terraform.lock.hcl".format(rlocationpath(aspect_dir, ctx.workspace_name))
    golden = ctx.file.golden

    args = ctx.actions.args()
    args.add("-aspect=" + aspect_lock_rloc)
    args.add("-golden=" + rlocationpath(golden, ctx.workspace_name))
    if ctx.attr.regenerate_hint:
        args.add("-regenerate-hint=" + ctx.attr.regenerate_hint)

    args_file = _write_args_file(ctx, args, "lockdiff")
    executable = _symlink_executable(ctx, ctx.executable._lockdiff)

    runfiles = ctx.runfiles(files = [ctx.executable._lockdiff, args_file, aspect_dir, golden])
    runfiles = runfiles.merge(ctx.attr._lockdiff[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        testing.TestEnvironment({
            "RULES_TERRAFORM_LOCKDIFF_ARGS_FILE": rlocationpath(args_file, ctx.workspace_name),
        }),
    ]

def build_providers_lock(ctx, toolchain_type):
    """Shared `terraform_providers_lock` / `opentofu_providers_lock` rule impl.

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

    # Only main-repo, source-tree .tf files — the reference tool seeds a
    # temp dir with these and runs real `<engine> providers lock`, so files
    # from external repos or generated files aren't relevant here.
    srcs = [
        src
        for src in target_info.srcs.to_list()
        if src.is_source and not src.short_path.startswith("../")
    ]
    if not srcs:
        fail("terraform_providers_lock requires target with source .tf files under the workspace root")

    output_rel = ctx.attr.output
    if ctx.label.package:
        output_rel = "{}/{}".format(ctx.label.package, output_rel)

    platforms = ctx.attr.platforms or _DEFAULT_LOCK_PLATFORMS

    # Root module directory in the source tree — used by lockref to compute
    # each src's relative position when seeding the temp dir. For a target
    # like `//tests/with_mixed_deps:with_mixed_deps` this is
    # `tests/with_mixed_deps`; the local module reference
    # `module "foo" { source = "./mymod" }` then resolves correctly.
    root_pkg = ctx.attr.target.label.package

    args = ctx.actions.args()
    args.add("-engine=" + rlocationpath(toolchain.terraform, ctx.workspace_name))
    args.add("-out=${BUILD_WORKSPACE_DIRECTORY}/" + output_rel)
    args.add("-root=${BUILD_WORKSPACE_DIRECTORY}/" + root_pkg)
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
        doc = "The terraform_module whose .tf sources drive the lock resolution.",
        providers = [TerraformInfo],
        mandatory = True,
    ),
    "_lockref": attr.label(
        executable = True,
        cfg = "exec",
        default = Label("//terraform/private/lockref"),
    ),
}

# `terraform_providers_lock` / `opentofu_providers_lock` are produced by
# the shared factory (`//terraform/private:engine_factory.bzl`) so both
# engines share the same rule body. Re-exported from
# `//terraform:terraform_modules_lock.bzl` and
# `//opentofu:opentofu_providers_lock.bzl`.

terraform_lock_diff_test = rule(
    doc = """Diffs the init-aspect-generated `.terraform.lock.hcl` for
    `target` against a checked-in golden produced by real
    `terraform init` / `tofu init`. Verifies same provider set, same
    version+constraints per provider, same `zh:` set, and at least one
    `h1:` overlap.""",
    implementation = _terraform_lock_diff_test_impl,
    attrs = {
        "golden": attr.label(
            doc = "A `.terraform.lock.hcl` produced by real terraform/tofu init.",
            allow_single_file = [".terraform.lock.hcl"],
            mandatory = True,
        ),
        "regenerate_hint": attr.string(
            doc = "Command shown in the failure message telling users how to refresh the golden.",
        ),
        "target": attr.label(
            doc = "A terraform_module target. The init aspect runs against it to produce the lock under test.",
            providers = [TerraformInfo],
            aspects = [terraform_init_aspect],
            mandatory = True,
        ),
        "_lockdiff": attr.label(
            executable = True,
            cfg = "target",
            default = Label("//terraform/private/lockdiff"),
        ),
    },
    test = True,
)
