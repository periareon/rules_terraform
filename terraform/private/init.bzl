"""Terraform init rules.

`terraform_init_aspect` is shared with `//opentofu` — the aspect only cares
about the on-disk layout Terraform and OpenTofu both consume.
"""

load(":args.bzl", "build_file_manifest", "write_json_args")
load(
    ":providers.bzl",
    "TerraformExternalModuleInfo",
    "TerraformInfo",
    "TerraformModuleGroupInfo",
    "TerraformProviderGroupInfo",
    "TerraformProviderInfo",
)

visibility(["//opentofu/...", "//terraform/...", "//tests/..."])

_DEFAULT_PLATFORM = "linux_amd64"

def _terraform_init_aspect_impl(target, ctx):
    """Aspect implementation that constructs the .terraform directory for a terraform_module."""
    if TerraformInfo not in target:
        return []

    terraform_info = target[TerraformInfo]

    terraform_dir = ctx.actions.declare_directory("{}.terraform".format(target.label.name))

    provider_group = None
    provider_group_lock = None
    provider_info_map = {}
    provider_files_depsets = []

    external_modules = []
    external_module_files_depsets = []

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
            elif TerraformModuleGroupInfo in dep:
                for mod_info in dep[TerraformModuleGroupInfo].modules:
                    external_modules.append(mod_info)
                    external_module_files_depsets.append(mod_info.files)
            elif TerraformExternalModuleInfo in dep:
                ext_mod = dep[TerraformExternalModuleInfo]
                external_modules.append(ext_mod)
                external_module_files_depsets.append(ext_mod.files)

    if terraform_info.external_modules:
        for ext_mod in terraform_info.external_modules.to_list():
            already = False
            for existing in external_modules:
                if existing.key == ext_mod.key:
                    already = True
                    break
            if not already:
                external_modules.append(ext_mod)
                external_module_files_depsets.append(ext_mod.files)

    lock_file = provider_group_lock if provider_group_lock else terraform_info.lock

    # Provider files land in the action's `transitive` depset below via
    # `provider_files_depsets`; adding them here too would duplicate every
    # provider file across a large monorepo's aspect graph.
    inputs = []
    if lock_file:
        inputs.append(lock_file)

    root_srcs = [src for src in terraform_info.srcs.to_list() if src.is_source]
    inputs.extend(root_srcs)

    # Output paths stay as strings — routing them through the path-mapped
    # paths file would cycle (the paths file is an action input; declaring
    # our own output in it makes the action depend on itself).
    # See //terraform/private:args.bzl for path-mapping design.
    args_data = {
        "output_dir": terraform_dir.path,
    }

    if root_srcs:
        args_data["source_files"] = root_srcs

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
                    "key": ext_mod.key,
                    "source": ext_mod.source,
                    "subdir": ext_mod.subdir,
                    "version": ext_mod.version,
                })
        if ext_mod_list:
            args_data["external_modules"] = ext_mod_list

    # Module source mappings — each mapping points at a dep whose sources
    # need to appear under the given `source_path` in the .terraform tree.
    mapped_module_depsets = []
    if terraform_info.module_sources:
        dep_manifests = {}
        if hasattr(ctx.rule.attr, "deps"):
            for dep in ctx.rule.attr.deps:
                if TerraformInfo in dep:
                    dep_info = dep[TerraformInfo]
                    dep_srcs = dep_info.srcs.to_list()
                    if dep_srcs:
                        dep_manifests[str(dep.label)] = build_file_manifest(
                            dep_srcs,
                            "mapped module dep {}".format(dep.label),
                        )
                        mapped_module_depsets.append(dep_info.srcs)

        mapped_mods = []
        for source_path, label_str in terraform_info.module_sources.items():
            manifest = None
            for dep_label, dep_manifest in dep_manifests.items():
                if dep_label.endswith(label_str.split("//")[-1]) or dep_label == label_str:
                    manifest = dep_manifest
                    break
            if manifest:
                mapped_mods.append({
                    "files": manifest,
                    "source_path": source_path,
                })
        if mapped_mods:
            args_data["mapped_modules"] = mapped_mods

    template_file, paths_file = write_json_args(
        ctx,
        "{}.terraform_init".format(target.label.name),
        args_data,
    )

    all_inputs = depset(
        [template_file, paths_file] + inputs,
        transitive = provider_files_depsets + external_module_files_depsets + mapped_module_depsets,
    )

    init_args = ctx.actions.args()
    init_args.add(template_file, format = "-args=%s")
    init_args.add(paths_file, format = "-paths=%s")

    ctx.actions.run(
        mnemonic = "TerraformInit",
        progress_message = "TerraformInit %{label}",
        executable = ctx.executable._init_tool,
        inputs = all_inputs,
        outputs = [terraform_dir],
        arguments = [init_args],
        tools = [ctx.executable._init_tool],
    )

    return [OutputGroupInfo(
        terraform_init = depset([terraform_dir]),
    )]

terraform_init_aspect = aspect(
    implementation = _terraform_init_aspect_impl,
    doc = "An aspect that constructs the .terraform directory for terraform_module targets.",
    attrs = {
        "_init_tool": attr.label(
            cfg = "exec",
            executable = True,
            default = Label("//terraform/private/init"),
        ),
    },
    required_providers = [TerraformInfo],
)
