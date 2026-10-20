"""Registry-module resolution for the `deps` tag's `roots`.

`extension_impl.bzl` calls `resolve_registry_modules` once per tag and
`declare_module_pool` once per evaluation. Per module block:

1. Resolve each `roots` label to a filesystem path, enumerate every `*.tf`
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
6. Once every tag is resolved, register one `terraform_module_repository`
   per distinct (registry, module address, version) across *all* hubs —
   the pool. The hub itself is declared by `extension_impl.bzl`.

## Why a pool

Hubs are per root module; the archives they need mostly are not. Two
environments calling the same `vpc` module, or a module reached both
directly and through another module, are one download. Keying
repositories by what the archive is, rather than by which hub asked,
means the extraction happens once and every hub aliases it. A
`//subdir` reference is a target inside that one repository, not a
second copy of the archive stripped differently.

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

load(":module_repo.bzl", "module_target_name", "terraform_module_repository")
load(
    ":registry.bzl",
    "is_registry_source",
    "resolve_archive_url",
    "resolve_version",
    "split_module_subdir",
)
load(":semver.bzl", "parse_constraints")
load(":tfparse.bzl", "parse_module_blocks")

visibility(["//terraform/...", "//tofu/..."])

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
    """Concatenate every `*.tf` and `*.tofu` file directly inside `dir_path`."""
    if not dir_path.exists:
        return ""
    combined = []
    for entry in dir_path.readdir():
        if entry.is_dir or not (entry.basename.endswith(".tf") or entry.basename.endswith(".tofu")):
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

def _pool_key(registry, base_source, version):
    """Identity of one fetched archive, which is also its repository name."""
    return "rt_mod_{}_{}_{}".format(registry, base_source.replace("/", "_"), version)

def resolve_registry_modules(module_ctx, *, name, roots, registry, existing_facts, new_facts, pool):
    """Resolve the registry modules named under `roots` for one `deps` tag.

    Declares nothing. Archives are recorded in `pool`, and the hub's members
    are returned, so the caller can declare each archive once after every
    tag has been seen.

    Args:
        module_ctx: (module_ctx) The extension context.
        name: (str) The hub name, for messages.
        roots: (list[Label]) `.tf` files naming the directories to scan.
        registry: (str) Registry hostname for sources that name none.
        existing_facts: (Facts|None) The previous eval's persisted facts
            (or None if `module_ctx.facts` isn't available).
        new_facts: (dict) Mutable dict of facts to write on this eval.
            Populated with entries for every currently-declared module,
            whether cached or freshly resolved.
        pool: (dict) Shared across tags, mutated in place. Maps pool
            repository name to a dict describing the archive and the
            `subdirs` requested of it so far.

    Returns:
        (list[str]) Labels of the pool targets this hub resolved to.
    """
    root_labels = roots

    # One hub may cover many directories. Each is read once even if listed
    # twice, and the blocks from all of them seed one worklist.
    blocks = []
    seen_dirs = {}
    for label in root_labels:
        dir_path = module_ctx.path(label).dirname
        if str(dir_path) in seen_dirs:
            continue
        seen_dirs[str(dir_path)] = True
        blocks.extend(parse_module_blocks(_read_tf_dir(module_ctx, dir_path)))

    # A registry module is routinely composed of others, and the engine will
    # not resolve a `module` block just because its parent was fetched. So the
    # worklist starts at the root's own blocks and grows as each fetched module
    # is scanned, rather than being the one list of blocks beside `tag.root`.
    #
    # Entries are `(source, constraint, key)`; `key` is the block name for a
    # root-level block and empty for anything discovered deeper, kept for
    # diagnostics. `queued` drops a reference already on the list *before*
    # it is pushed: a diamond in the module graph reaches the same
    # `(source, constraint)` down every path, and deduplicating only at pop
    # time would pay a `/versions` round trip for each one and count each
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

    members = []
    resolved = {}

    # Archive per `(source-without-subdir, version)`, not per reference: two
    # `//subdir` references into one module are two repos cut from one
    # download.
    archives = {}

    for _ in range(_MAX_REGISTRY_MODULES):
        if not pending:
            break

        # Breadth first, so the root module's own blocks are all resolved
        # before anything found inside a fetched module: a constraint written
        # by the user is resolved before one written by a dependency.
        source, constraint, _ = pending.pop(0)

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

        # The archive is pooled under its own identity; this hub only notes
        # which module inside it was wanted. The repository renders one target
        # per subdir asked for, across every hub, from one extraction.
        pool_key = _pool_key(registry, base_source, version)
        if pool_key not in pool:
            pool[pool_key] = {
                "base_source": base_source,
                "integrity": integrity,
                "strip_prefix": strip_prefix,
                "subdirs": {},
                "url": archive_url,
                "version": version,
            }
        pool[pool_key]["subdirs"][subdir] = True
        members.append("@{}//:{}".format(pool_key, module_target_name(subdir)))

    if pending:
        fail("`{}` pulls in more than {} distinct registry modules".format(
            name,
            _MAX_REGISTRY_MODULES,
        ))

    return members

def claim_hub_name(claimed, name, module_name, kind):
    """Record that `module_name` declared a hub called `name`, or fail if taken.

    Every repository an extension declares shares one namespace, whichever
    Bazel module asked for it. Two `name = "providers"` tags from two modules
    would otherwise fail inside bzlmod as a duplicate repository, with neither
    tag named.

    Args:
        claimed: (dict) Mutated in place; hub name → description of claimant.
        name: (str) The hub name being claimed.
        module_name: (str) The Bazel module declaring it.
        kind: (str) The tag class, for the message.
    """
    claimant = "{} tag in module '{}'".format(kind, module_name)
    if name in claimed:
        fail("hub name '{}' is declared twice: by a {} and by a {}. Hub names are shared across every module using this extension; pick distinct ones.".format(
            name,
            claimed[name],
            claimant,
        ))
    claimed[name] = claimant

def declare_module_pool(pool):
    """Declare one `http_archive` per entry of the pool built by `resolve_registry_modules`.

    Args:
        pool: (dict) Pool repository name → archive dict.
    """
    for repo_name, entry in pool.items():
        terraform_module_repository(
            name = repo_name,
            source = entry["base_source"],
            version = entry["version"],
            url = entry["url"],
            integrity = entry["integrity"],
            strip_prefix = entry["strip_prefix"],
            subdirs = sorted(entry["subdirs"].keys()),
        )
