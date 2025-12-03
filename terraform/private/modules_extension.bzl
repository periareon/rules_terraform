"""Shared impl of the `terraform.modules(...)` / `opentofu.modules(...)` tag class.

Both engine-specific extensions delegate here — their `_impl` bodies
reduce to a single call to `resolve_all_modules(module_ctx, registry_default)`
below. Per module block:

1. Resolve the `root` label to a filesystem path, enumerate every `*.tf`
   sibling via `module_ctx.path(root).dirname.readdir()`, and read each.
2. Parse `module { }` blocks (`tfparse.parse_module_blocks`).
3. For each registry-shaped source, resolve the concrete version. If the
   block already pins an exact SemVer AND we have a cached entry for
   that (source, version) in `module_ctx.facts`, skip network entirely
   and reuse the cached URL + integrity.
4. On cache miss: hit the Registry v1 API to resolve the archive URL
   (`registry.bzl`), then download the archive body to compute a
   sha256 integrity. Cache the result in `facts` for next eval.
5. Register a `terraform_module_repository` per module + the
   `terraform_module_hub` wrapping them.

## Why facts

Per-(source, version) archive URL + strip_prefix + integrity are
historical facts — same values forever, no matter when you resolve
them. Bzlmod's `module_ctx.facts` is the designed mechanism for
extension-owned persistent state across evals. Bazel serializes the
returned dict into `MODULE.bazel.lock` (or the equivalent), so the
next re-eval of the extension (which happens whenever any `.tf` file
in the root module directory changes) sees the same facts and can
short-circuit both the Registry metadata call AND the archive download.

The extension only writes facts for `(source, version)` pairs actually
referenced by a currently-declared `module { }` block. Entries for
removed modules disappear on the next eval — dead facts don't
accumulate.

## Reproducibility

Extension remains `reproducible = False`: the `/versions` endpoint is
still called for constraint-based version resolution (`~> 5.0` could
land on different concrete versions over time as new releases publish).
Exact-pinned + facts-cached blocks skip every network call, but the
extension's reproducibility guarantee has to hold for all inputs, and
we can't statically prove every block is pinned. See
`docs/src/index.md#reproducibility`.
"""

load(":module_repo.bzl", "terraform_module_hub", "terraform_module_repository")
load(
    ":registry.bzl",
    "is_registry_source",
    "resolve_archive_url",
    "resolve_version",
)
load(":semver.bzl", "parse_constraints")
load(":tfparse.bzl", "parse_module_blocks")

visibility(["//opentofu/...", "//terraform/..."])

def _read_sibling_tf_files(module_ctx, root_label):
    """Read every `*.tf` file in the directory containing `root_label`."""
    root_path = module_ctx.path(root_label)
    dir_path = root_path.dirname
    entries = dir_path.readdir()
    combined = []
    for entry in entries:
        name = entry.basename
        if not name.endswith(".tf"):
            continue
        combined.append(module_ctx.read(entry))
    return "\n".join(combined)

def _sanitize_repo_segment(s):
    return s.replace("-", "_").replace("/", "_")

def _exact_pin_version(constraint):
    """Return the canonical SemVer string if `constraint` is a single `=` clause, else None.

    Normalizes `"1.0.0"`, `"= 1.0.0"`, `"v1.0.0"`, and `"= v1.0.0"` all
    to `"1.0.0"` — the raw block string would otherwise leak the `= `
    prefix or `v` into registry URLs and fact keys.

    Args:
        constraint: (str) A `version = "…"` value from a `module { }` block.

    Returns:
        (str|None) The canonical version string, or None if the
        constraint isn't a single-clause exact pin.
    """
    parsed = parse_constraints(constraint)
    if parsed == None or len(parsed) != 1 or parsed[0].op != "=":
        return None
    v = parsed[0].version
    canonical = "{}.{}.{}".format(v.major, v.minor, v.patch)
    if v.prerelease:
        canonical += "-" + v.prerelease
    return canonical

def _fact_key(source, version):
    return "{}@{}".format(source, version)

def _resolve_one(module_ctx, tag, registry_default, existing_facts, new_facts):
    """Resolve one `terraform.modules(...)` / `opentofu.modules(...)` tag.

    Args:
        module_ctx: (module_ctx) The extension context.
        tag: The parsed tag instance; needs `name`, `root`, and
            `registry` (may be empty to signal "use default").
        registry_default: (str) Registry hostname used when the tag's
            `registry` attr is empty.
        existing_facts: (Facts|None) The previous eval's persisted facts
            (or None if `module_ctx.facts` isn't available).
        new_facts: (dict) Mutable dict of facts to write on this eval.
            Populated with entries for every currently-declared module,
            whether cached or freshly resolved.
    """
    registry = tag.registry if tag.registry else registry_default

    content = _read_sibling_tf_files(module_ctx, tag.root)
    blocks = parse_module_blocks(content)

    module_repo_names = []
    for block in blocks:
        if not is_registry_source(block.source):
            continue

        # For exact pins we skip the `/versions` call entirely; the
        # pinned version is already the concrete resolution — but read
        # it back canonicalized (no `= ` prefix, no leading `v`) so it
        # can be used as a registry URL segment and fact key.
        pinned = _exact_pin_version(block.version)
        version = pinned if pinned else resolve_version(
            module_ctx,
            registry,
            block.source,
            block.version,
        )
        key = _fact_key(block.source, version)
        cached = existing_facts[key] if existing_facts != None and key in existing_facts else None

        if cached:
            # Reuse the cached dict directly — no realloc.
            new_facts[key] = cached
            archive_url = cached["url"]
            strip_prefix = cached["strip_prefix"]
            integrity = cached["integrity"]
        else:
            archive = resolve_archive_url(module_ctx, registry, block.source, version)
            hash_result = module_ctx.download(
                url = archive.url,
                output = "archive_{}_{}.tar.gz".format(
                    _sanitize_repo_segment(block.source),
                    _sanitize_repo_segment(version),
                ),
                sha256 = "",
            )
            if not hash_result.success:
                fail("failed to download archive for {} @ {} from {}".format(
                    block.source,
                    version,
                    archive.url,
                ))
            archive_url = archive.url
            strip_prefix = archive.strip_prefix
            integrity = hash_result.integrity
            new_facts[key] = {
                "integrity": integrity,
                "strip_prefix": strip_prefix,
                "url": archive_url,
            }

        repo_name = "{}_{}".format(tag.name, _sanitize_repo_segment(block.key))
        terraform_module_repository(
            name = repo_name,
            key = block.key,
            source = block.source,
            version = version,
            url = archive_url,
            integrity = integrity,
            strip_prefix = strip_prefix,
        )
        module_repo_names.append(repo_name)

    terraform_module_hub(
        name = tag.name,
        module_repos = module_repo_names,
    )

def resolve_all_modules(module_ctx, registry_default):
    """Run the modules-tag orchestration end-to-end for one engine.

    Reads facts, iterates every `modules` tag under `module_ctx`, and
    builds the `extension_metadata` return. Both
    `//terraform:extensions.bzl` and `//opentofu:extensions.bzl` call
    this — the only per-engine difference is `registry_default`.

    Args:
        module_ctx: (module_ctx) The extension context.
        registry_default: (str) Hostname used when a tag's `registry`
            attr is empty (`registry.terraform.io` /
            `registry.opentofu.org`).

    Returns:
        (extension_metadata) `reproducible = False` metadata carrying
        the current eval's facts. On Bazel 7 (no facts API), returns
        metadata without the `facts` kwarg so the extension still
        works — no caching, every re-eval pays the full network cost.
    """
    supports_facts = hasattr(module_ctx, "facts")
    existing_facts = module_ctx.facts if supports_facts else None
    new_facts = {}

    for mod in module_ctx.modules:
        for attrs in mod.tags.modules:
            _resolve_one(
                module_ctx,
                attrs,
                registry_default = registry_default,
                existing_facts = existing_facts,
                new_facts = new_facts,
            )

    # `reproducible = False` — module version constraints (`~> 5.0`,
    # `>= 1.0`) resolve against the live Registry API and can pick
    # different versions over time as new releases publish. Pin every
    # `module {}` block to an exact SemVer to make resolution
    # deterministic.
    kwargs = {"reproducible": False}
    if supports_facts:
        kwargs["facts"] = new_facts
    return module_ctx.extension_metadata(**kwargs)
