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
   (`registry.bzl`), then download and extract the archive to compute a
   sha256 integrity and to read the module's own `module` blocks. Cache
   both in `facts` for next eval.
5. Feed those blocks back into step 3. A registry module is commonly
   composed of others, and the engine resolves the whole graph, so
   fetching only what the root names leaves the rest uninstalled.
6. Register a `terraform_module_repository` per distinct (source,
   version) + the `terraform_module_hub` wrapping them.

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
    "split_module_subdir",
)
load(":semver.bzl", "parse_constraints")
load(":tfparse.bzl", "parse_module_blocks")

visibility(["//opentofu/...", "//terraform/..."])

# Starlark has no unbounded loops, so the two tree walks below are written as
# worklists driven by a `range`. Both limits are far above any real module —
# they exist to turn a malformed tree into a diagnostic instead of a hang.
#
# Both count *distinct* things, directories and `(source, version)` references
# respectively, because both worklists drop a duplicate before it is pushed.
# A limit on pops would instead count paths through the graph, and a module
# graph with a few diamonds in it has far more paths than modules.
_MAX_MODULE_DIRS = 2048
_MAX_REGISTRY_MODULES = 512

def _read_tf_dir(module_ctx, dir_path):
    """Concatenate every `*.tf` file directly inside `dir_path`."""
    if not dir_path.exists:
        return ""
    combined = []
    for entry in dir_path.readdir():
        if entry.is_dir or not entry.basename.endswith(".tf"):
            continue
        combined.append(module_ctx.read(entry))
    return "\n".join(combined)

def _resolve_relative(base, rel, floor):
    """Resolve a `./`- or `../`-relative module source against `base`.

    Args:
        base: (path) Directory the source was written in.
        rel: (str) The relative source.
        floor: (path) Directory the result must stay within.

    Returns:
        (path|None) The resolved directory, or None when `rel` climbs above
        `floor`.
    """
    current = base
    for segment in rel.split("/"):
        if segment == "" or segment == ".":
            continue
        elif segment == "..":
            current = current.dirname
        else:
            current = current.get_child(segment)

    # Without a floor a `../../` source reads whatever sits beside the
    # extraction directory — including the other modules' extract dirs, whose
    # blocks would then be baked into this module's persisted `deps`.
    if str(current) != str(floor) and not str(current).startswith(str(floor) + "/"):
        return None
    return current

def _registry_refs(module_ctx, start_path, floor):
    """Registry `module` sources reachable from `start_path`.

    Follows local (`./`, `../`) sources the way the engine does rather than
    globbing for `*.tf`: a registry module ships `examples/` and `tests/` trees
    whose `module` blocks reference modules the configuration never calls, and
    fetching those would balloon the dependency set for nothing.

    Args:
        module_ctx: (module_ctx) The extension context.
        start_path: (path) Directory holding the module's own `*.tf` files.
        floor: (path) Extraction root. A `../` source may climb out of
            `start_path` — a `//subdir` module reaching back into its own
            archive is the normal case — but not out of the archive, which is
            the whole of what was fetched. Sources that do are skipped, the
            same ones the init tool documents as unplaceable.

    Returns:
        (list[struct]) `struct(source, version)` per registry block found.
    """
    refs = []
    seen = {}
    stack = [start_path]
    for _ in range(_MAX_MODULE_DIRS):
        if not stack:
            break
        dir_path = stack.pop()

        # A shared child module reached from several blocks is one directory
        # with one set of blocks; walking it per path that arrives at it would
        # duplicate refs and, for a self-referencing tree, never terminate.
        if str(dir_path) in seen:
            continue
        seen[str(dir_path)] = True

        for block in parse_module_blocks(_read_tf_dir(module_ctx, dir_path)):
            if is_registry_source(block.source):
                refs.append(struct(source = block.source, version = block.version))
            elif block.source.startswith("./") or block.source.startswith("../"):
                child = _resolve_relative(dir_path, block.source, floor)
                if child != None and str(child) not in seen:
                    stack.append(child)
    if stack:
        fail("module tree under {} exceeds {} directories".format(start_path, _MAX_MODULE_DIRS))
    return refs

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

def _ref_key(source, constraint):
    """Worklist identity of an unresolved reference.

    Keyed on the constraint as written rather than the version it resolves to,
    because the point is to avoid doing the resolution twice.
    """
    return "{}@@{}".format(source, constraint)

def _fetch_archive(module_ctx, registry, base_source, version, archives):
    """Download and unpack one module archive, at most once per eval.

    Args:
        module_ctx: (module_ctx) The extension context.
        registry: (str) Registry hostname to resolve metadata against.
        base_source: (str) Registry source with any `//subdir` already off.
        version: (str) Concrete version.
        archives: (dict) Memo of archives already fetched this eval, mutated
            in place.

    Returns:
        (struct) `struct(url, strip_prefix, integrity, path)`, where `path` is
        the extraction root.
    """
    memo_key = _fact_key(base_source, version)
    if memo_key in archives:
        return archives[memo_key]

    archive = resolve_archive_url(module_ctx, registry, base_source, version)
    extract_dir = "module_{}_{}".format(
        _sanitize_repo_segment(base_source),
        _sanitize_repo_segment(version),
    )

    # Extracted rather than merely downloaded because the archive is the only
    # place the module's own `module` blocks can be read from.
    result = module_ctx.download_and_extract(
        url = archive.url,
        output = extract_dir,
        stripPrefix = archive.strip_prefix,
        sha256 = "",
    )
    if not result.success:
        fail("failed to download archive for {} @ {} from {}".format(
            base_source,
            version,
            archive.url,
        ))

    archives[memo_key] = struct(
        url = archive.url,
        strip_prefix = archive.strip_prefix,
        integrity = result.integrity,
        path = module_ctx.path(extract_dir),
    )
    return archives[memo_key]

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

    root_path = module_ctx.path(tag.root).dirname
    blocks = parse_module_blocks(_read_tf_dir(module_ctx, root_path))

    # A registry module is routinely composed of others, and the engine will
    # not resolve a `module` block just because its parent was fetched. So the
    # worklist starts at the root's own blocks and grows as each fetched module
    # is scanned, rather than being the one list of blocks beside `tag.root`.
    #
    # Entries are `(source, constraint, key)`; `key` is the block name for a
    # root-level block and empty for anything discovered deeper, where no
    # single block names the module. `queued` drops a reference already on the
    # list *before* it is pushed: a diamond in the module graph reaches the
    # same `(source, constraint)` down every path, and deduplicating only at
    # pop time would pay a `/versions` round trip for each one and count each
    # one against the worklist limit.
    pending = []
    queued = {}
    for block in blocks:
        if not is_registry_source(block.source):
            continue
        if _ref_key(block.source, block.version) in queued:
            continue
        queued[_ref_key(block.source, block.version)] = True
        pending.append((block.source, block.version, block.key))

    module_repo_names = []
    resolved = {}

    # Archive per `(source-without-subdir, version)`, not per reference: two
    # `//subdir` references into one module are two repos cut from one
    # download.
    archives = {}

    for _ in range(_MAX_REGISTRY_MODULES):
        if not pending:
            break

        # Breadth first, so the root module's own blocks are all resolved
        # before anything found inside a fetched module. A module reached both
        # ways then takes its repo name from the block that names it rather
        # than from whichever path happened to be walked first.
        source, constraint, block_key = pending.pop(0)

        # The registry addresses the whole module; `//subdir` picks out one
        # module published inside it. Everything up to the archive is keyed on
        # the address, everything after it on the full source.
        base_source, subdir = split_module_subdir(source)

        # For exact pins we skip the `/versions` call entirely; the
        # pinned version is already the concrete resolution — but read
        # it back canonicalized (no `= ` prefix, no leading `v`) so it
        # can be used as a registry URL segment and fact key.
        pinned = _exact_pin_version(constraint)
        version = pinned if pinned else resolve_version(
            module_ctx,
            registry,
            base_source,
            constraint,
        )
        key = _fact_key(source, version)

        # Two constraints can still name one version (`~> 5.0` and `5.3.1`),
        # which `queued` cannot see and which is one repo, not two.
        if key in resolved:
            continue
        resolved[key] = True

        cached = existing_facts[key] if existing_facts != None and key in existing_facts else None

        # Facts written before transitive resolution have no `deps`, and an
        # absent list is indistinguishable from an empty one. Re-fetch those so
        # the children are not silently dropped; the entry is rewritten below.
        if cached and "deps" in cached:
            # Reuse the cached dict directly — no realloc.
            new_facts[key] = cached
            archive_url = cached["url"]
            strip_prefix = cached["strip_prefix"]
            integrity = cached["integrity"]
            deps = cached["deps"]
        else:
            archive = _fetch_archive(module_ctx, registry, base_source, version, archives)
            archive_url = archive.url
            strip_prefix = archive.strip_prefix
            integrity = archive.integrity

            # Read from the subdir when there is one, but let a `../` source
            # climb back into the rest of the archive — a published submodule
            # referencing its siblings that way is the normal case.
            start_path = archive.path
            for segment in subdir.split("/"):
                if segment:
                    start_path = start_path.get_child(segment)

            deps = [
                {"source": ref.source, "version": ref.version}
                for ref in _registry_refs(module_ctx, start_path, archive.path)
            ]
            new_facts[key] = {
                "deps": deps,
                "integrity": integrity,
                "strip_prefix": strip_prefix,
                "url": archive_url,
            }

        for dep in deps:
            if _ref_key(dep["source"], dep["version"]) in queued:
                continue
            queued[_ref_key(dep["source"], dep["version"])] = True
            pending.append((dep["source"], dep["version"], ""))

        # A module nobody named gets a name from its own identity. Two versions
        # of one module are two repos, so the version has to be in there — and
        # so does the subdir, since two submodules of one archive are two more.
        repo_segment = block_key if block_key else "{}_{}".format(
            _sanitize_repo_segment(source),
            _sanitize_repo_segment(version),
        )
        repo_name = "{}_{}".format(tag.name, _sanitize_repo_segment(repo_segment))
        terraform_module_repository(
            name = repo_name,
            key = repo_segment,
            # The full source, subdir and all, because the init tool matches a
            # `module` block against this string and the block wrote the subdir.
            source = source,
            version = version,
            url = archive_url,
            integrity = integrity,
            strip_prefix = strip_prefix,
            subdir = subdir,
        )
        module_repo_names.append(repo_name)

    if pending:
        fail("`{}` pulls in more than {} distinct registry modules".format(
            tag.name,
            _MAX_REGISTRY_MODULES,
        ))

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
