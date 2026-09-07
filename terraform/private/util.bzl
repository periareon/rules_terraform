"""Shared utilities for Terraform Bazel rules."""

visibility(["//opentofu/...", "//terraform/...", "//tests/..."])

def staged_path(file):
    """Return the path a module staging tree places `file` at, relative to its root.

    Args:
        file: (File) A file that will be placed in a module staging tree.

    Returns:
        (str) A slash-separated path. External-repository files lose the
        leading `../` so they land under `<repo_name>/...`.
    """
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return file.short_path

def rlocationpath(file, workspace_name):
    """Convert a file to its runfiles location path.

    Args:
        file: (File) A File object.
        workspace_name: (str) The workspace name string.

    Returns:
        (str) The rlocationpath string for the file.
    """
    staged = staged_path(file)

    # An external-repository file's staged path is already repo-rooted, so it
    # is the rlocationpath; a main-repo one needs the workspace prefix.
    if file.short_path.startswith("../"):
        return staged
    return "{}/{}".format(workspace_name, staged)

def staged_dir(file):
    """Return the directory part of `file`'s staged path.

    Args:
        file: (File) A file that will be placed in a module staging tree.

    Returns:
        (str) The staged path with the basename removed, or `""` for a file
        at the staging root.
    """
    staged = staged_path(file)
    if "/" not in staged:
        return ""
    return staged.rsplit("/", 1)[0]

def strip_canonical_repo_prefix(name):
    """Recover the tag-supplied `name` from a canonical repo name.

    Extension-generated repos are canonicalized as `<module>+<ext>+<name>`
    on Bazel 8+ and `<module>~<ext>~<name>` on Bazel 7. Drops everything
    up to the last separator so the result is safe to use as a Bazel
    target name.

    Args:
        name: (str) A `repository_ctx.name` value or equivalent.

    Returns:
        (str) The tail after the last `+` or `~`, whichever appears last.
    """
    return name.rsplit("+", 1)[-1].rsplit("~", 1)[-1]

def module_dir(target):
    """Return the module directory produced by `terraform_init_aspect`.

    Args:
        target: (Target) A Bazel target the init aspect has been applied to.

    Returns:
        (File|None) The declared module directory tree artifact, or None if
        the aspect didn't run or produced no output.
    """
    if OutputGroupInfo not in target:
        return None
    output_groups = target[OutputGroupInfo]
    if not hasattr(output_groups, "terraform_init"):
        return None
    entries = output_groups.terraform_init.to_list()
    return entries[0] if entries else None
