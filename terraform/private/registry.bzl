"""Terraform Registry v1 module API helpers, callable from a bzlmod extension.

Two entry points:

- `resolve_version(module_ctx, registry, source, constraint) -> str` —
  hits `/v1/modules/…/versions`, resolves the module block's version
  constraint against the returned list via `semver.highest_matching`.
- `resolve_archive_url(module_ctx, registry, source, version) -> struct` —
  hits `/v1/modules/…/<version>` for metadata, reads `source` (git URL)
  + `tag` (git tag), constructs a direct GitHub tarball URL +
  strip_prefix. Fails clearly for non-GitHub git hosts (feature parity
  with the previous Go-side `lockgen` rewriter).

Every `.tf` block reference costs three network calls at extension eval
time: versions list, per-version metadata, and archive body (for the
sha256). Once resolved, the registered `http_archive` fetches direct
from GitHub — no registry hop at build time.
"""

load(":semver.bzl", "highest_matching", "parse_constraints", "parse_version")

visibility(["//opentofu/...", "//terraform/..."])

def _registry_source(source):
    """Strip a leading `hostname/` from a 4-segment registry source."""
    parts = source.split("/")
    if len(parts) == 4:
        return "/".join(parts[1:])
    return source

def _download_json(module_ctx, url, output):
    result = module_ctx.download(url = url, output = output, sha256 = "")
    if not result.success:
        fail("failed to download {}".format(url))
    return json.decode(module_ctx.read(output))

def resolve_version(module_ctx, registry, source, constraint):
    """Resolve a module block's version constraint against the Registry.

    Args:
        module_ctx: (module_ctx) The extension context.
        registry: (str) Hostname, e.g. `registry.terraform.io`.
        source: (str) Registry source like `cloudposse/label/null` (or the
            4-segment form with a leading hostname).
        constraint: (str) Constraint expression from the module block's
            `version = "…"`. Empty matches everything.

    Returns:
        (str) The resolved version (as it appears in the registry —
        includes any leading `v` if the registry lists it that way).
    """
    reg_source = _registry_source(source)
    url = "https://{registry}/v1/modules/{source}/versions".format(
        registry = registry,
        source = reg_source,
    )
    output = "versions_{}.json".format(reg_source.replace("/", "_"))
    data = _download_json(module_ctx, url, output)

    modules = data.get("modules", [])
    if not modules or not modules[0].get("versions"):
        fail("registry returned no versions for {}".format(source))

    parsed = []
    for entry in modules[0]["versions"]:
        v = parse_version(entry["version"])
        if v != None:
            parsed.append(v)

    constraints = parse_constraints(constraint)
    if constraints == None:
        fail("invalid version constraint {} on module {}".format(repr(constraint), source))

    picked = highest_matching(parsed, constraints)
    if picked == None:
        if not constraint:
            fail("no valid versions found for {}".format(source))
        fail("no version of {} satisfies constraint {}".format(source, repr(constraint)))
    return picked.original

def _normalize_git_source(git_source):
    s = git_source
    if s.endswith("/"):
        s = s[:-1]
    if s.endswith(".git"):
        s = s[:-len(".git")]
    return s

def _github_tarball(source_url, tag):
    """Construct a direct GitHub tarball URL + strip_prefix for `tag`.

    Args:
        source_url: (str) GitHub repo URL like
            `https://github.com/cloudposse/terraform-null-label`.
        tag: (str) The git tag corresponding to the picked version.

    Returns:
        (struct) `struct(url, strip_prefix)`.
    """
    base = _normalize_git_source(source_url)
    slash = base.rfind("/")
    if slash < 0:
        fail("cannot extract repo name from {}".format(source_url))
    repo = base[slash + 1:]

    tag_no_v = tag[1:] if tag.startswith("v") else tag
    return struct(
        url = "{}/archive/refs/tags/{}.tar.gz".format(base, tag),
        strip_prefix = "{}-{}".format(repo, tag_no_v),
    )

def resolve_archive_url(module_ctx, registry, source, version):
    """Resolve the direct archive URL + strip_prefix for a module version.

    Args:
        module_ctx: (module_ctx) The extension context.
        registry: (str) Registry hostname.
        source: (str) Registry source (`<ns>/<name>/<provider>`).
        version: (str) Resolved version string from `resolve_version`.

    Returns:
        (struct) `struct(url, strip_prefix)` pointing at a fetchable
        tarball. Fails for non-GitHub git hosts.
    """
    reg_source = _registry_source(source)
    url = "https://{registry}/v1/modules/{source}/{version}".format(
        registry = registry,
        source = reg_source,
        version = version,
    )
    output = "metadata_{}_{}.json".format(
        reg_source.replace("/", "_"),
        version.replace("/", "_"),
    )
    data = _download_json(module_ctx, url, output)

    git_source = data.get("source")
    tag = data.get("tag")
    if not git_source or not tag:
        fail(
            ("registry metadata for {}@{} is missing `source` or `tag`; " +
             "the module may not be resolvable to a git-backed archive").format(source, version),
        )

    lowered = git_source.lower()
    if lowered.startswith("https://github.com/") or lowered.startswith("https://www.github.com/"):
        return _github_tarball(git_source, tag)

    fail(
        ("unsupported git host in module {}@{}: {}\n" +
         "only https://github.com/… is supported today.").format(source, version, git_source),
    )

def is_registry_source(source):
    """Return True iff `source` looks like a Terraform Registry reference.

    Excludes local paths, git URLs, and other non-registry schemes;
    mirrors the classification used by the old `lockgen` binary.

    Args:
        source: (str) The `source` value from a Terraform `module { }`
            block.

    Returns:
        (bool) True if `source` is a registry-shaped reference.
    """
    if not source:
        return False
    for prefix in ("./", "../", "/", "git::", "git@", "http://", "https://", "s3::", "gcs::"):
        if source.startswith(prefix):
            return False
    return len(source.split("/")) >= 3
