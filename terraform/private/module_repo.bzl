"""Repository rules for external Terraform modules."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(":util.bzl", "strip_canonical_repo_prefix")

_MODULE_REPO_BUILD_FILE = """\
load("@rules_terraform//terraform/private:terraform.bzl", "terraform_external_module")

terraform_external_module(
    name = "module",
    key = "{key}",
    source = "{source}",
    version = "{version}",
    subdir = "{subdir}",
    srcs = glob(
        ["**/*.tf", "**/*.tf.json"],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)
"""

_MODULE_HUB_BUILD_FILE = """\
load("@rules_terraform//terraform/private:terraform.bzl", "terraform_module_group")

terraform_module_group(
    name = "{name}",
    deps = [
{deps}
    ],
    visibility = ["//visibility:public"],
)
"""

def terraform_module_repository(*, name, key, source, version, url, integrity, strip_prefix = "", subdir = ""):
    """Download an external Terraform module and create a repository.

    Args:
        name: (str) Repository name.
        key: (str) Module key from the lock file.
        source: (str) Registry source (e.g., `terraform-aws-modules/vpc/aws`).
        version: (str) Module version.
        url: (str) Download URL for the module archive.
        integrity: (str) Subresource Integrity hash.
        strip_prefix: (str) Prefix to strip from the extracted archive
            (e.g., GitHub tarballs come wrapped in `<repo>-<sha>/`).
        subdir: (str) Optional subdirectory *within* the module source
            that holds the module root (recorded from Terraform's
            `//subdir` "get" suffix).

    Returns:
        (str) The provided `name` (for chaining convenience).
    """
    effective_strip = strip_prefix
    if subdir:
        # subdir names the module root inside the source; combine it with any
        # archive-wrapper strip so http_archive lands directly at the module root.
        effective_strip = "{}/{}".format(strip_prefix, subdir) if strip_prefix else subdir

    http_archive(
        name = name,
        urls = [url],
        integrity = integrity,
        strip_prefix = effective_strip,
        build_file_content = _MODULE_REPO_BUILD_FILE.format(
            key = key,
            source = source,
            version = version,
            subdir = subdir,
        ),
    )

    return name

def _terraform_module_hub_impl(repository_ctx):
    """Repository rule implementation for module hub."""
    repository_ctx.file("WORKSPACE.bazel", 'workspace(name = "{}")'.format(
        repository_ctx.name,
    ))

    deps = []
    for module_repo in repository_ctx.attr.module_repos:
        deps.append('        "@{}//:module",'.format(module_repo))

    repository_ctx.file("BUILD.bazel", _MODULE_HUB_BUILD_FILE.format(
        name = strip_canonical_repo_prefix(repository_ctx.name),
        deps = "\n".join(deps),
    ))

terraform_module_hub = repository_rule(
    doc = "Aggregates external module repositories into a single hub.",
    attrs = {
        "module_repos": attr.string_list(
            doc = "List of module repository names.",
            mandatory = True,
        ),
    },
    implementation = _terraform_module_hub_impl,
)
