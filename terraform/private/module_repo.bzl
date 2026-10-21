"""Repository rules for external Terraform modules.

Archives live in a pool shared by every `deps` hub: one repository per
(registry, module address, version), extracted once, with a target per
`//subdir` any hub referenced. The hub itself is `deps_hub.bzl`.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

_MODULE_REPO_BUILD_HEADER = """\
load("@rules_terraform//terraform/private:terraform.bzl", "terraform_external_module")
"""

_MODULE_REPO_TARGET = """
terraform_external_module(
    name = "{target}",
    source = "{source}",
    version = "{version}",
    srcs = glob(
        [{globs}],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)
"""

def module_target_name(subdir):
    """Name of the target inside a pool repository that serves `subdir`.

    Args:
        subdir: (str) A `//subdir` suffix without the slashes, or `""` for
            the module at the archive root.

    Returns:
        (str) `module` for the root, otherwise `module_<subdir>` with path
        separators and dashes folded to underscores.
    """
    if not subdir:
        return "module"
    return "module_" + subdir.replace("/", "_").replace("-", "_").replace(".", "_")

def _module_repo_build_file(source, version, subdirs):
    targets = []
    for subdir in subdirs:
        full_source = "{}//{}".format(source, subdir) if subdir else source
        prefix = subdir + "/" if subdir else ""
        globs = ", ".join([
            '"{}**/*.{}"'.format(prefix, ext)
            for ext in ("tf", "tf.json", "tofu", "tofu.json")
        ])
        targets.append(_MODULE_REPO_TARGET.format(
            target = module_target_name(subdir),
            source = full_source,
            version = version,
            globs = globs,
        ))
    return _MODULE_REPO_BUILD_HEADER + "".join(targets)

def terraform_module_repository(*, name, source, version, url, integrity, strip_prefix = "", subdirs = [""]):
    """Download one module archive and expose every module inside it a hub asked for.

    Args:
        name: (str) Repository name.
        source: (str) Registry source without any `//subdir`
            (e.g., `terraform-aws-modules/eks/aws`).
        version: (str) Module version.
        url: (str) Download URL for the module archive.
        integrity: (str) Subresource Integrity hash.
        strip_prefix: (str) Archive wrapper to strip (GitHub tarballs come
            wrapped in `<repo>-<tag>/`). The archive is extracted whole
            below that; subdirectories are selected per target, not by
            stripping, so one extraction serves every `//subdir`.
        subdirs: (list[str]) The module roots inside the archive to expose,
            `""` for the archive root itself. One
            `terraform_external_module` target is rendered per entry; see
            `module_target_name`.

    Returns:
        (str) The provided `name` (for chaining convenience).
    """
    http_archive(
        name = name,
        urls = [url],
        integrity = integrity,
        strip_prefix = strip_prefix,
        build_file_content = _module_repo_build_file(source, version, subdirs),
    )

    return name
