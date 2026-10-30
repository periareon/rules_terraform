"""Recognize and take apart the git-shaped `module` sources Terraform accepts.

Terraform hands a non-registry, non-local source to go-getter, which fetches
it from git when it is written one of three ways:

* forced: `git::https://host/org/repo.git?ref=v1.4.0`,
  `git::ssh://git@host/org/repo.git?ref=v1.4.0`;
* scp-like: `git@host:org/repo.git?ref=v1.4.0`;
* GitHub shorthand: `github.com/org/repo`, which go-getter rewrites to
  `git::https://github.com/org/repo.git`.

Each may carry `//subdir` after the repository and `?ref=` after that. The
ref may be a branch, a tag or a commit; without one the remote's default
branch is meant.

This file knows nothing about Bazel repositories or the registry. It exists
so the registry classifier can rule git sources out before counting slashes
(`github.com/org/repo` has as many as a registry address) and so the
extension and its tests agree on one parser.
"""

visibility(["//terraform/...", "//tofu/...", "//tests/..."])

_HEX = "0123456789abcdef"

def _split_query(s):
    idx = s.find("?")
    if idx < 0:
        return s, {}
    params = {}
    for param in s[idx + 1:].split("&"):
        if not param:
            continue
        if "=" in param:
            key, value = param.split("=", 1)
        else:
            key, value = param, ""
        params[key] = value
    return s[:idx], params

def _split_subdir(address):
    """Split `//subdir` off a git address, leaving the `//` of a URL scheme alone."""
    start = 0
    scheme = address.find("://")
    if scheme >= 0:
        start = scheme + len("://")
    idx = address.find("//", start)
    if idx < 0:
        return address, ""
    return address[:idx], address[idx + 2:].strip("/")

def parse_git_source(source):
    """Take a git-shaped module source apart.

    Args:
        source: (str) The `source` value of a `module { }` block.

    Returns:
        (struct|None) `struct(remote, ref, subdir)` for a git source, where
        `remote` is the address git itself should be given, `ref` is the
        `?ref=` value or `""`, and `subdir` is the `//subdir` suffix or `""`.
        None for anything that is not a git source.
    """
    if not source:
        return None

    lowered = source.lower()
    if lowered.startswith("git::"):
        address = source[len("git::"):]
    elif lowered.startswith("git@"):
        address = source
    elif lowered.startswith("github.com/") or lowered.startswith("www.github.com/"):
        address = "https://" + source
    else:
        return None

    address, params = _split_query(address)
    remote, subdir = _split_subdir(address)
    if not remote:
        return None

    if lowered.startswith("github.com/") or lowered.startswith("www.github.com/"):
        # go-getter adds `.git` to the shorthand; so does this, so the one
        # repository is not fetched twice under two spellings.
        if not remote.endswith(".git"):
            remote += ".git"

    return struct(
        remote = remote,
        ref = params.get("ref", ""),
        subdir = subdir,
    )

def is_git_source(source):
    """Whether `source` is one Terraform would fetch from git.

    Args:
        source: (str) The `source` value of a `module { }` block.

    Returns:
        (bool)
    """
    return parse_git_source(source) != None

def is_commit(ref):
    """Whether `ref` is a full commit id rather than a branch or tag name.

    A full id needs no lookup to know which commit it is, so the extension
    can declare it without asking the remote. An abbreviated id is treated
    like a tag and resolved.

    Args:
        ref: (str) A git ref.

    Returns:
        (bool)
    """
    if len(ref) != 40 and len(ref) != 64:
        return False
    for c in ref.elems():
        if c not in _HEX:
            return False
    return True
