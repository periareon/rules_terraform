"""The hub repository one `deps` tag produces.

`@<name>` is a `terraform_dependency_group`: every provider the tag's lock
pins, that lock, and every registry module the tag's `roots` name. A
`terraform_module` depends on it and needs no `lock` of its own. Two
sub-targets split it for modules that want one half: `@<name>//:providers`
(the providers and the lock) and `@<name>//:modules` (the registry modules),
and `@<name>//<namespace>_<name>` is one provider, for a module installing
a subset.

Nothing is fetched here. Archives live in pools shared by every hub
(`provider_repo.bzl`, `module_repo.bzl`); this repository is aliases over
them plus the lock file.
"""

load(":platforms.bzl", "PLATFORM_TO_CONSTRAINTS")
load(":util.bzl", "strip_canonical_repo_prefix")

_ROOT_BUILD = """\
\"\"\"Dependency hub {hub_name}\"\"\"

load(
    "@rules_terraform//terraform/private:terraform.bzl",
    "terraform_dependency_group",
    "terraform_module_group",
    "terraform_provider_group",
)

package(default_visibility = ["//visibility:public"])

# Everything the tag resolved: depend on this and the module needs no `lock`.
terraform_dependency_group(
    name = "{group_name}",
    providers = [
{provider_deps}
    ],
    modules = [
{module_deps}
    ],
{lock_attr})

# The registry modules alone, for a library that should not install providers.
terraform_module_group(
    name = "modules",
    deps = [
{module_deps}
    ],
)
{providers_group}"""

_PROVIDERS_GROUP = """
# The providers and the lock alone.
terraform_provider_group(
    name = "providers",
    deps = [
{provider_deps}
    ],
    lock = "{lock_file}",
)
"""

_PROVIDER_SUBPACKAGE_BUILD_FILE = """alias(
    name = "{target_name}",
    actual = select({{
{select_cases}
    }}),
    visibility = ["//visibility:public"],
)
"""

def _provider_subpackages(provider_repos_str):
    """Per-provider subpackages: a `select()` over the pool's platform repos."""
    providers_by_source = {}
    for key_str, repo_name in provider_repos_str.items():
        parts = key_str.split(":", 1)
        if len(parts) != 2:
            continue
        providers_by_source.setdefault(parts[0], []).append((parts[1], repo_name))

    subpackages = {}
    for provider_source, platforms in providers_by_source.items():
        namespace, provider_name = provider_source.split("/")[0], provider_source.split("/")[1]
        subpackage_name = "{}_{}".format(namespace, provider_name.replace("-", "_"))
        select_cases = [
            '        "@rules_terraform//terraform/private/constraints:{}": "@{}//:provider",'.format(platform, repo_name)
            for platform, repo_name in platforms
            if platform in PLATFORM_TO_CONSTRAINTS
        ]
        subpackages[subpackage_name] = _PROVIDER_SUBPACKAGE_BUILD_FILE.format(
            target_name = subpackage_name,
            select_cases = "\n".join(select_cases),
        )
    return subpackages

def _terraform_deps_hub_impl(repository_ctx):
    repository_ctx.file("WORKSPACE.bazel", 'workspace(name = "{}")\n'.format(repository_ctx.name))

    lock_file = ""
    if repository_ctx.attr.lock_file_label:
        lock_file = ".terraform.lock.hcl"
        repository_ctx.file(lock_file, repository_ctx.read(repository_ctx.attr.lock_file_label))

    subpackages = _provider_subpackages(repository_ctx.attr.provider_repos)
    provider_deps = "\n".join(['        "//{0}:{0}",'.format(name) for name in sorted(subpackages.keys())])
    module_deps = "\n".join(['        "{}",'.format(target) for target in repository_ctx.attr.module_targets])

    repository_ctx.file("BUILD.bazel", _ROOT_BUILD.format(
        hub_name = repository_ctx.name,
        group_name = strip_canonical_repo_prefix(repository_ctx.name),
        provider_deps = provider_deps,
        module_deps = module_deps,
        lock_attr = '    lock = "{}",\n'.format(lock_file) if lock_file else "",
        providers_group = _PROVIDERS_GROUP.format(provider_deps = provider_deps, lock_file = lock_file) if lock_file else "",
    ))
    for subpackage_name, content in subpackages.items():
        repository_ctx.file("{}/BUILD.bazel".format(subpackage_name), content)

terraform_deps_hub = repository_rule(
    doc = "The hub a `deps` tag produces: a dependency group over pooled provider and module archives, plus the lock.",
    attrs = {
        "lock_file_label": attr.label(
            doc = "The tag's lock file, copied into the hub. Absent for a tag with no `lock`.",
            allow_single_file = [".terraform.lock.hcl"],
        ),
        "module_targets": attr.string_list(
            doc = "Labels of `terraform_external_module` targets in the shared pool.",
        ),
        "provider_repos": attr.string_dict(
            doc = "Mapping of 'provider_source:platform' to pool repository name.",
        ),
    },
    implementation = _terraform_deps_hub_impl,
)
