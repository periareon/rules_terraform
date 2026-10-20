"""Terraform Registry v1 module API helpers, callable from a bzlmod extension.

Two entry points:

- `resolve_version(module_ctx, registry, source, constraint) -> str` —
  hits `/v1/modules/…/versions`, resolves the module block's version
  constraint against the returned list via `semver.highest_matching`.
- `resolve_archive_url(module_ctx, registry, source, version) -> struct` —
  asks `/v1/modules/…/<version>` for metadata (`source` + `tag`, a
  registry.terraform.io extension) and falls back to the protocol's
  `/download` endpoint (a go-getter `location`, which is what
  registry.opentofu.org answers with). Either way the result is a direct
  GitHub archive URL + strip_prefix. Fails clearly for other git hosts.

Every `.tf` block reference costs three network calls at extension eval
time: versions list, per-version metadata, and archive body (for the
sha256). Once resolved, the registered `http_archive` fetches direct
from GitHub — no registry hop at build time.
"""

load(":semver.bzl", "highest_matching", "parse_constraints", "parse_version")

visibility(["//terraform/...", "//tofu/..."])

def _registry_source(source, registry):
    """Split a module source into the registry to ask and the address to ask for.

    A 4-segment source carries its own hostname
    (`app.terraform.io/org/vpc/aws`), and that host is the only place the
    module exists; the extension's default registry applies to the 3-segment
    public form.

    Args:
        source: (str) Registry source, with or without a leading hostname.
        registry: (str) Hostname to use when `source` has none.

    Returns:
        (tuple[str, str]) `(registry_host, namespace/name/provider)`.
    """
    parts = source.split("/")
    if len(parts) == 4:
        return parts[0], "/".join(parts[1:])
    return registry, source

def _download_json(module_ctx, url, output):
    result = module_ctx.download(url = url, output = output, sha256 = "")
    if not result.success:
        fail("failed to download {}".format(url))
    return json.decode(module_ctx.read(output))

def resolve_version(module_ctx, registry, source, constraint):
    """Resolve a module block's version constraint against the Registry.

    Args:
        module_ctx: (module_ctx) The extension context.
        registry: (str) Hostname, e.g. `registry.terraform.io`, used when
            `source` does not name one.
        source: (str) Registry source like `cloudposse/label/null`, or the
            4-segment form with a leading hostname, which is then the
            registry queried.
        constraint: (str) Constraint expression from the module block's
            `version = "…"`. Empty matches everything.

    Returns:
        (str) The resolved version (as it appears in the registry —
        includes any leading `v` if the registry lists it that way).
    """
    registry, reg_source = _registry_source(source, registry)
    url = "https://{registry}/v1/modules/{source}/versions".format(
        registry = registry,
        source = reg_source,
    )
    output = "versions_{}_{}.json".format(registry, reg_source.replace("/", "_"))
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

def _github_archive_for_ref(repo_url, ref):
    """A GitHub archive URL + strip_prefix for a commit or tag `ref`."""
    base = _normalize_git_source(repo_url)
    slash = base.rfind("/")
    if slash < 0:
        fail("cannot extract repo name from {}".format(repo_url))
    repo = base[slash + 1:]

    # GitHub names the directory inside a tag archive after the tag with a
    # leading `v` removed; a commit archive is named after the full SHA.
    dir_ref = ref[1:] if ref.startswith("v") and len(ref) > 1 and ref[1].isdigit() else ref
    return struct(
        url = "{}/archive/{}.tar.gz".format(base, ref),
        strip_prefix = "{}-{}".format(repo, dir_ref),
    )

def _archive_from_location(location, source, version):
    """Turn a registry `download` location into an archive URL.

    The protocol hands back a go-getter address. The two shapes seen from the
    public registries are a `git::https://github.com/<o>/<r>?ref=<ref>` source
    and a direct GitHub archive URL; anything else is a host this ruleset
    cannot fetch from without a Bazel repository rule of the user's own.
    """
    loc = location
    if loc.startswith("git::"):
        loc = loc[len("git::"):]
    lowered = loc.lower()
    if not (lowered.startswith("https://github.com/") or lowered.startswith("https://www.github.com/")):
        fail(
            ("unsupported module location for {}@{}: {}\n" +
             "only https://github.com/… is supported today; fetch the module with your own " +
             "repository rule and a terraform_external_module instead.").format(source, version, location),
        )
    if "/archive/" in loc:
        # Already an archive. GitHub's directory naming still applies.
        path = loc.split("/archive/", 1)
        ref = path[1]
        for suffix in (".tar.gz", ".zip"):
            if ref.endswith(suffix):
                ref = ref[:-len(suffix)]
        ref = ref.split("/")[-1]
        return _github_archive_for_ref(path[0], ref)

    repo_url = loc
    ref = ""
    if "?" in loc:
        repo_url, query = loc.split("?", 1)
        for param in query.split("&"):
            if param.startswith("ref="):
                ref = param[len("ref="):]
    if not ref:
        fail("module location for {}@{} names no ref: {}".format(source, version, location))
    return _github_archive_for_ref(repo_url, ref)

def resolve_archive_url(module_ctx, registry, source, version):
    """Resolve the direct archive URL + strip_prefix for a module version.

    Two registry answers are understood. `registry.terraform.io` extends the
    protocol with a per-version metadata document carrying the git `source`
    and `tag`. The protocol's own `download` endpoint, which is what
    `registry.opentofu.org` implements, answers with a go-getter location,
    pinned to a commit. Both end at a GitHub archive URL.

    Args:
        module_ctx: (module_ctx) The extension context.
        registry: (str) Registry hostname.
        source: (str) Registry source (`<ns>/<name>/<provider>`).
        version: (str) Resolved version string from `resolve_version`.

    Returns:
        (struct) `struct(url, strip_prefix)` pointing at a fetchable
        tarball. Fails for non-GitHub git hosts.
    """
    registry, reg_source = _registry_source(source, registry)
    safe = "{}_{}_{}".format(registry, reg_source.replace("/", "_"), version.replace("/", "_"))

    metadata_url = "https://{registry}/v1/modules/{source}/{version}".format(
        registry = registry,
        source = reg_source,
        version = version,
    )
    result = module_ctx.download(url = metadata_url, output = "metadata_{}.json".format(safe), allow_fail = True)
    if result.success:
        data = json.decode(module_ctx.read("metadata_{}.json".format(safe)), default = None)
        if type(data) == "dict" and data.get("source") and data.get("tag"):
            git_source = data["source"]
            lowered = git_source.lower()
            if lowered.startswith("https://github.com/") or lowered.startswith("https://www.github.com/"):
                return _github_tarball(git_source, data["tag"])
            fail(
                ("unsupported git host in module {}@{}: {}\n" +
                 "only https://github.com/… is supported today.").format(source, version, git_source),
            )

    download_url = "https://{registry}/v1/modules/{source}/{version}/download".format(
        registry = registry,
        source = reg_source,
        version = version,
    )
    result = module_ctx.download(url = download_url, output = "download_{}.json".format(safe), allow_fail = True)
    if result.success:
        data = json.decode(module_ctx.read("download_{}.json".format(safe)), default = None)
        if type(data) == "dict" and data.get("location"):
            return _archive_from_location(data["location"], source, version)

    fail(
        ("{registry} gave no usable answer for module {source}@{version}: neither the " +
         "version metadata endpoint ({meta}) nor the download endpoint ({dl}) returned a " +
         "location this ruleset can fetch from.").format(
            registry = registry,
            source = source,
            version = version,
            meta = metadata_url,
            dl = download_url,
        ),
    )

def split_module_subdir(source):
    """Split Terraform's `<module>//<subdir>` suffix off a module source.

    A registry module may publish several modules in one repository, and a
    `module` block reaches the inner ones with a double slash:
    `terraform-aws-modules/eks/aws//modules/karpenter`. The registry API knows
    nothing about the suffix — it addresses the whole module — so it has to
    come off before any URL is built from the source, and come back on when
    the archive is unpacked.

    Only call this on a source `is_registry_source` has accepted: the `//` in
    `https://…` is not a subdir separator.

    Args:
        source: (str) A registry-shaped `source` value.

    Returns:
        (tuple[str, str]) `(source_without_subdir, subdir)`; `subdir` is `""`
        when the source has no suffix.
    """
    idx = source.find("//")
    if idx < 0:
        return source, ""
    subdir = source[idx + 2:].strip("/")
    return source[:idx], subdir

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

    # Shape is decided on the address alone. A `//subdir` suffix says which
    # module inside the source is wanted, not whether the source is a registry
    # one, and counting its segments would let any path with enough slashes in
    # it pass for a registry reference.
    base, _ = split_module_subdir(source)
    return len(base.split("/")) >= 3
