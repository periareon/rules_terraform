"""Terraform init rules.

`terraform_init_aspect` builds the module *directory* — the whole thing an
engine needs to run in: the root module's own `.tf` files, local child modules
at the relative paths their `module` blocks name, and a populated
`.terraform/` alongside. Emitting a complete directory as one tree artifact is
what lets the runner and the validate tool just copy it and `cd` in, instead of
each reconstructing the layout from a runfiles manifest.

The tree is rooted at the deepest common ancestor of the root module and its
local module deps, and the engine runs in the `workdir` subpath within it. For
a module with no deps outside its own directory those are the same place. They
differ for the monorepo layout where a root module several directories deep
reaches up into a shared library — `source = "../../../modules/network"` — which
only resolves if there is tree above the root module to climb into.

Shared with `//opentofu` — the aspect only cares about the on-disk layout
Terraform and OpenTofu both consume.
"""

load(":args.bzl", "build_file_manifest", "write_json_args")
load(
    ":providers.bzl",
    "TerraformInfo",
    "TerraformProviderGroupInfo",
    "TerraformProviderInfo",
)
load(":util.bzl", "staged_path")

visibility(["//opentofu/...", "//terraform/...", "//tests/..."])

_DEFAULT_PLATFORM = "linux_amd64"

def _module_relative_manifest(files, root_dir, context):
    """Return a copy manifest placing `files` relative to a module directory.

    Every manifest in the module tree — the root's own files, a nested child
    module's, a cross-package child's — is expressed against the directory it
    will be rooted at, so one builder covers all of them.

    Args:
        files: (list[File]) Files to place. `terraform_module` guarantees they
            all live under the owning module's directory.
        root_dir: (str) That module's staged directory.
        context: (str) Human-readable label for the fail message.

    Returns:
        (list[dict]) `{"src": File, "dst": str}` entries.
    """
    manifest = []
    root_prefix = root_dir + "/" if root_dir else ""
    for f in files:
        staged = staged_path(f)
        if not staged.startswith(root_prefix):
            fail("{}: file {} does not live under the module directory {}".format(context, staged, root_dir))
        manifest.append({"dst": staged[len(root_prefix):], "src": f})
    return manifest

def _common_ancestor(dirs):
    """Return the deepest directory that prefixes every entry of `dirs`.

    Args:
        dirs: (list[str]) Slash-separated staged directories. `""` means the
            staging root.

    Returns:
        (str) The common prefix on a segment boundary, `""` if there is none.
    """
    common = None
    for d in dirs:
        segments = d.split("/") if d else []
        if common == None:
            common = segments
            continue
        shared = 0
        for i in range(min(len(common), len(segments))):
            if common[i] != segments[i]:
                break
            shared += 1
        common = common[:shared]
    return "/".join(common) if common else ""

def _tree_relative(dir, tree_root):
    """Return `dir` expressed relative to `tree_root`.

    Args:
        dir: (str) A staged directory at or below `tree_root`.
        tree_root: (str) The directory the tree artifact is rooted at.

    Returns:
        (str) The relative path, `""` when `dir` is `tree_root` itself.
    """
    if not tree_root:
        return dir
    if dir == tree_root:
        return ""
    return dir[len(tree_root) + 1:]

def _terraform_init_aspect_impl(target, ctx):
    """Aspect implementation that constructs the module directory for a terraform_module."""
    if TerraformInfo not in target:
        return []

    terraform_info = target[TerraformInfo]

    module_dir = ctx.actions.declare_directory("{}.module".format(target.label.name))
    root_dir = terraform_info.root_dir

    provider_group = None
    provider_group_lock = None
    provider_info_map = {}
    provider_files_depsets = []

    if hasattr(ctx.rule.attr, "deps"):
        for dep in ctx.rule.attr.deps:
            if TerraformProviderGroupInfo in dep:
                if provider_group != None:
                    fail("terraform_init_aspect: target '{}' has more than one terraform_provider_group in deps".format(target.label))
                provider_group = dep[TerraformProviderGroupInfo]
                provider_group_lock = provider_group.lock
                for provider_info in provider_group.providers:
                    provider_info_map[provider_info.source] = provider_info
                    provider_files_depsets.append(provider_info.files)
            elif TerraformProviderInfo in dep:
                provider_info = dep[TerraformProviderInfo]
                if provider_group != None:
                    group_provider_sources = [p.source for p in provider_group.providers]
                    if provider_info.source not in group_provider_sources:
                        fail("terraform_init_aspect: target '{}' has terraform_provider '{}' that is not in the terraform_provider_group".format(
                            target.label,
                            provider_info.source,
                        ))
                provider_info_map[provider_info.source] = provider_info
                provider_files_depsets.append(provider_info.files)

    # The whole closure, not just `ctx.rule.attr.deps`: a registry module is
    # declared next to the `module` block naming it, which is usually a shared
    # library rather than the root.
    external_modules = terraform_info.external_modules.to_list()
    external_module_files_depsets = [ext_mod.files for ext_mod in external_modules]

    lock_file = provider_group_lock if provider_group_lock else terraform_info.lock

    # A `module` block's source is resolved relative to the directory holding
    # the `.tf` file, so a `../` source names somewhere *above* the root module.
    # Rooting the tree at the deepest common ancestor of the root module and
    # every local dep is what gives those a place to land: the engine runs in
    # `workdir` within the tree, and climbing out of it stays inside the
    # artifact. With no deps, or only deps nested under the root, the ancestor
    # is the root module itself and `workdir` is empty — the layout is
    # unchanged for everything that worked before.
    local_deps = terraform_info.deps.to_list()
    tree_root = _common_ancestor([root_dir] + [dep_info.root_dir for dep_info in local_deps])
    workdir = _tree_relative(root_dir, tree_root)

    # Every dep goes out as a candidate rather than being placed by path here.
    # Only the init tool can know where a dep belongs — the `source` strings
    # that name it exist solely inside the `.tf` files.
    module_file_depsets = [terraform_info.srcs, terraform_info.data]
    local_module_depsets = []
    local_modules = []
    for dep_info in local_deps:
        local_module_depsets.extend([dep_info.srcs, dep_info.data])
        local_modules.append({
            "dir": _tree_relative(dep_info.root_dir, tree_root),
            "files": _module_relative_manifest(
                depset(transitive = [dep_info.srcs, dep_info.data]).to_list(),
                dep_info.root_dir,
                "module dep {}".format(dep_info.root_dir),
            ),
            "package": dep_info.root_dir,
        })
    module_files = _module_relative_manifest(
        depset(transitive = module_file_depsets).to_list(),
        root_dir,
        "module {}".format(target.label),
    )

    # Output paths stay as strings — routing them through the path-mapped
    # paths file would cycle (the paths file is an action input; declaring
    # our own output in it makes the action depend on itself).
    # See //terraform/private:args.bzl for path-mapping design.
    args_data = {
        "module_files": module_files,
        "output_dir": module_dir.path,
    }

    if workdir:
        args_data["workdir"] = workdir

    if local_modules:
        args_data["local_modules"] = local_modules

    if lock_file:
        args_data["lock_file"] = lock_file

    if terraform_info.providers and lock_file:
        providers_list = []
        for provider_source, provider_info in provider_info_map.items():
            platform = provider_info.platform if provider_info.platform else _DEFAULT_PLATFORM
            provider_files = provider_info.files.to_list()
            if provider_files:
                providers_list.append({
                    "files": build_file_manifest(
                        provider_files,
                        "provider {}".format(provider_source),
                    ),
                    "platform": platform,
                    "source": provider_source,
                    "version": provider_info.version if provider_info.version else "",
                })

        if providers_list:
            args_data["providers"] = providers_list

    if external_modules:
        ext_mod_list = []
        for ext_mod in external_modules:
            mod_files = ext_mod.files.to_list()
            if mod_files:
                ext_mod_list.append({
                    "files": build_file_manifest(
                        mod_files,
                        "external module {}".format(ext_mod.key),
                    ),
                    "source": ext_mod.source,
                    "subdir": ext_mod.subdir,
                    "version": ext_mod.version,
                })
        if ext_mod_list:
            args_data["external_modules"] = ext_mod_list

    template_file, paths_file = write_json_args(
        ctx,
        "{}.terraform_init".format(target.label.name),
        args_data,
    )

    all_inputs = depset(
        [template_file, paths_file] + ([lock_file] if lock_file else []),
        transitive = (
            provider_files_depsets +
            external_module_files_depsets +
            local_module_depsets +
            module_file_depsets
        ),
    )

    init_args = ctx.actions.args()
    init_args.add(template_file, format = "-args=%s")
    init_args.add(paths_file, format = "-paths=%s")

    ctx.actions.run(
        mnemonic = "TerraformInit",
        progress_message = "TerraformInit %{label}",
        executable = ctx.executable._init_tool,
        inputs = all_inputs,
        outputs = [module_dir],
        arguments = [init_args],
        tools = [ctx.executable._init_tool],
    )

    return [OutputGroupInfo(
        terraform_init = depset([module_dir]),
    )]

terraform_init_aspect = aspect(
    implementation = _terraform_init_aspect_impl,
    doc = "An aspect that constructs the runnable module directory for terraform_module targets.",
    attrs = {
        "_init_tool": attr.label(
            cfg = "exec",
            executable = True,
            default = Label("//terraform/private/init"),
        ),
    },
    required_providers = [TerraformInfo],
)
