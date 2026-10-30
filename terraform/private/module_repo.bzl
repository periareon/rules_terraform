"""Repository rules for external Terraform modules.

Fetched modules live in a pool shared by every `deps` hub: one repository
per registry archive (registry, module address, version) or per git
checkout (remote, commit), fetched once, with a target per module inside it
that any hub referenced. The hub itself is `deps_hub.bzl`.
"""

load("@bazel_tools//tools/build_defs/repo:git.bzl", "new_git_repository")
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

def _module_target(target, source, version, subdir):
    prefix = subdir + "/" if subdir else ""
    globs = ", ".join([
        '"{}**/*.{}"'.format(prefix, ext)
        for ext in ("tf", "tf.json", "tofu", "tofu.json")
    ])
    return _MODULE_REPO_TARGET.format(
        target = target,
        source = source,
        version = version,
        globs = globs,
    )

def _module_repo_build_file(source, version, subdirs):
    targets = []
    for subdir in subdirs:
        full_source = "{}//{}".format(source, subdir) if subdir else source
        targets.append(_module_target(module_target_name(subdir), full_source, version, subdir))
    return _MODULE_REPO_BUILD_HEADER + "".join(targets)

def _verbatim_build_file(modules):
    """A BUILD file with one target per `module` block spelling, no version.

    Terraform's manifest reader insists a version parse as a semantic
    version, and a git module is identified by its source alone.
    """
    return _MODULE_REPO_BUILD_HEADER + "".join([
        _module_target(entry["target"], entry["source"], "", entry["subdir"])
        for entry in modules
    ])

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

def terraform_archive_module_repository(*, name, url, integrity, strip_prefix, modules):
    """Download one archive of a git repository and expose every module inside it a hub asked for.

    The git counterpart of `terraform_module_repository`, for a host that
    serves an archive per tag or commit (GitHub). Pinned by integrity, so it
    is fetched through the repository cache and needs no git on the host.

    Args:
        name: (str) Repository name.
        url: (str) Archive URL.
        integrity: (str) Subresource Integrity hash.
        strip_prefix: (str) The one directory the archive unpacks to.
        modules: (list[dict]) As for `terraform_git_module_repository`.

    Returns:
        (str) The provided `name` (for chaining convenience).
    """
    http_archive(
        name = name,
        urls = [url],
        integrity = integrity,
        strip_prefix = strip_prefix,
        build_file_content = _verbatim_build_file(modules),
    )

    return name

def terraform_git_module_repository(*, name, remote, commit, modules):
    """Check out one git commit and expose every module inside it a hub asked for.

    The checkout is done by Bazel's own `new_git_repository`, with the host's
    `git` and whatever credentials it has: an `ssh://` remote works wherever
    `git clone` of it would. The commit is exact, so the repository is
    reproducible without a checksum.

    Args:
        name: (str) Repository name.
        remote: (str) The address `git` is given, as parsed from the
            `module` block's source.
        commit: (str) Full commit id, resolved by the extension.
        modules: (list[dict]) One entry per `module` block spelling this
            checkout serves: `target` (the target name), `source` (the
            block's `source` verbatim, which the init aspect matches on)
            and `subdir` (the `//subdir`, `""` for the checkout root).

    Returns:
        (str) The provided `name` (for chaining convenience).
    """
    new_git_repository(
        name = name,
        remote = remote,
        commit = commit,
        build_file_content = _verbatim_build_file(modules),
    )

    return name
