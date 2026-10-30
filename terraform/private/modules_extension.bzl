"""External-module resolution for the `deps` tag's `roots`.

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

A git-shaped source (`git::…`, `git@…`, `github.com/…`; see
`git_source.bzl`) goes through the same worklist with a different fetch,
and its `?ref=` must be a tag or a full commit id: a branch moves, so a
branch name, or no ref at all, is an error. A GitHub `https` remote is
fetched as the archive GitHub serves for the ref, exactly like a registry
module: unpacked once on a facts miss to record its integrity and read its
own references, then declared as an `http_archive`, with no git involved.
Any other remote, `ssh://` to GitHub included, is checked out with the
host's `git` on a facts miss, the commit it names is recorded, and the
pool entry is a `new_git_repository` at that exact commit, so a private
remote works wherever `git clone` of it would.

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

A git tag is in the same position: what it names is looked up once and
recorded as a fact, as an archive integrity or a commit, and that is what
every later evaluation declares. A tag that is moved afterwards fails the
next fresh fetch on the archive path and is ignored on the git path. A
ref that is a full commit id is exact by construction.
"""

load(":git_source.bzl", "is_commit", "parse_git_source")
load(
    ":module_repo.bzl",
    "module_target_name",
    "terraform_archive_module_repository",
    "terraform_git_module_repository",
    "terraform_module_repository",
)
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

def _is_external(source):
    """Whether a `module` source names something the extension fetches."""
    return is_registry_source(source) or parse_git_source(source) != None

def _external_refs(module_ctx, start_path, floor):
    """Registry and git `module` sources reachable from `start_path`.

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
            if _is_external(block.source):
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

def _sanitize_name(s):
    """`s` reduced to the characters a repository name may contain."""
    return "".join([c if c.isalnum() or c in "._-" else "_" for c in s.elems()])

def _remote_name(remote):
    """A readable repository-name segment for a git remote: host and path, no scheme or suffix."""
    bare = remote.split("://", 1)[-1]
    if bare.startswith("git@"):
        bare = bare[len("git@"):]
    if bare.endswith(".git"):
        bare = bare[:-len(".git")]
    return _sanitize_name(bare)

def _is_github_https(remote):
    """Whether `remote` is GitHub over https, which serves archives Bazel can fetch without git."""
    lowered = remote.lower()
    return lowered.startswith("https://github.com/") or lowered.startswith("https://www.github.com/")

def _github_archive_url(remote, ref):
    """The GitHub archive of `ref`: by id for a commit, under `refs/tags/` for a tag.

    The tag form is deliberate. `archive/<name>.tar.gz` resolves a branch as
    readily as a tag; `archive/refs/tags/<name>.tar.gz` is not found for a
    branch, which is how a branch ref is refused on this path.
    """
    base = remote[:-1] if remote.endswith("/") else remote
    if base.endswith(".git"):
        base = base[:-len(".git")]
    if is_commit(ref):
        return "{}/archive/{}.tar.gz".format(base, ref)
    return "{}/archive/refs/tags/{}.tar.gz".format(base, ref)

def _fetch_github_archive(module_ctx, remote, ref, checkouts):
    """Download and unpack a GitHub archive during evaluation, at most once per eval.

    Args:
        module_ctx: (module_ctx) The extension context.
        remote: (str) An `https://github.com/…` remote.
        ref: (str) A tag or full commit id.
        checkouts: (dict) Memo of fetches already made this eval, mutated
            in place.

    Returns:
        (struct) `struct(url, strip_prefix, integrity, path)`, where `path`
        is the unpacked module root.
    """
    memo_key = "{}@{}".format(remote, ref)
    if memo_key in checkouts:
        return checkouts[memo_key]

    url = _github_archive_url(remote, ref)
    extract_dir = "git_{}_{}".format(_remote_name(remote), _sanitize_name(ref))
    result = module_ctx.download_and_extract(
        url = url,
        output = extract_dir,
        sha256 = "",
        allow_fail = True,
    )
    if not result.success:
        fail(("could not fetch module source {} at ref {} from {}.\n" +
              "{}").format(
            remote,
            ref,
            url,
            "The ref is not a tag. A git module is pinned to a tag or a full commit id; a branch name is not accepted." if not is_commit(ref) else "Check that the commit exists and that GitHub is reachable from this machine.",
        ))

    # GitHub names the directory inside after the repository and ref, with
    # a leading `v` dropped from a version-like tag. Reading the name back
    # beats predicting it: the prefix recorded here is what `http_archive`
    # strips later, and a wrong guess would fail only then.
    entries = [entry for entry in module_ctx.path(extract_dir).readdir()]
    if len(entries) != 1 or not entries[0].is_dir:
        fail("archive {} does not unpack to a single directory".format(url))

    checkouts[memo_key] = struct(
        url = url,
        strip_prefix = entries[0].basename,
        integrity = result.integrity,
        path = entries[0],
    )
    return checkouts[memo_key]

def _git(module_ctx, args, remote, ref, allow_failure = False):
    """Run `git` with `args`, failing with its stderr unless told to return it."""
    result = module_ctx.execute(
        ["git"] + args,
        environment = {"GIT_TERMINAL_PROMPT": "0"},
        timeout = 600,
    )
    if result.return_code != 0 and not allow_failure:
        fail("git {} failed for module source {}{}:\n{}".format(
            args[0] if args[0] != "-C" else args[2],
            remote,
            " at ref " + ref if ref else "",
            result.stderr.strip(),
        ))
    return result

def _git_tag_commit(module_ctx, remote, ref):
    """The commit a tag names on the remote, or a failure if `ref` is not a tag.

    `ls-remote --tags` lists the tag and, for an annotated tag, its peeled
    commit as `<name>^{}`. A branch appears in neither form, so a branch
    name is refused here before anything is fetched.
    """
    result = _git(module_ctx, ["ls-remote", "--tags", remote, ref], remote, ref)
    tag_commit = None
    peeled_commit = None
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        if parts[1] == "refs/tags/{}^{{}}".format(ref):
            peeled_commit = parts[0]
        elif parts[1] == "refs/tags/{}".format(ref):
            tag_commit = parts[0]
    commit = peeled_commit if peeled_commit else tag_commit
    if not commit:
        fail(("ref {} of module source {} is not a tag. A git module is pinned to a tag or a " +
              "full commit id; a branch name is not accepted.").format(ref, remote))
    return commit

def _fetch_git(module_ctx, remote, ref, checkouts):
    """Check out one git tag or commit during evaluation, at most once per eval.

    Only needed when the facts have nothing for the ref: it is how the
    extension learns which commit a tag names and which modules the
    checkout itself references. The repository Bazel builds against is a
    separate `new_git_repository` of the resolved commit.

    Args:
        module_ctx: (module_ctx) The extension context.
        remote: (str) The address `git` is given.
        ref: (str) A tag or full commit id.
        checkouts: (dict) Memo of checkouts already made this eval, mutated
            in place.

    Returns:
        (struct) `struct(commit, path)`, where `path` is the checkout root.
    """
    memo_key = "{}@{}".format(remote, ref)
    if memo_key in checkouts:
        return checkouts[memo_key]

    if module_ctx.which("git") == None:
        fail("module source {} is fetched from git, but no `git` is on PATH".format(remote))

    # A tag is fetched by its full ref name, so a branch that happens to
    # share the name cannot be what arrives.
    fetch_ref = ref if is_commit(ref) else "refs/tags/" + ref
    if not is_commit(ref):
        _git_tag_commit(module_ctx, remote, ref)

    path = module_ctx.path("git_{}_{}".format(_remote_name(remote), _sanitize_name(ref)))
    if path.exists:
        module_ctx.delete(path)
    _git(module_ctx, ["init", "-q", str(path)], remote, ref)
    _git(module_ctx, ["-C", str(path), "remote", "add", "origin", remote], remote, ref)

    # One commit's worth of history is all that is read. A commit named by
    # id can be fetched that way only where the server allows it; GitHub and
    # GitLab do, and anywhere else the whole history is taken instead.
    result = _git(module_ctx, ["-C", str(path), "fetch", "-q", "--depth", "1", "origin", fetch_ref], remote, ref, allow_failure = True)
    target = "FETCH_HEAD"
    if result.return_code != 0 and is_commit(ref):
        result = _git(module_ctx, ["-C", str(path), "fetch", "-q", "origin"], remote, ref, allow_failure = True)
        target = ref
    if result.return_code != 0:
        fail("git fetch of module source {} at ref {} failed:\n{}".format(remote, ref, result.stderr.strip()))
    _git(module_ctx, ["-C", str(path), "checkout", "-q", "--detach", target], remote, ref)
    commit = _git(module_ctx, ["-C", str(path), "rev-parse", "HEAD"], remote, ref).stdout.strip()

    checkouts[memo_key] = struct(commit = commit, path = path)
    return checkouts[memo_key]

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

def _git_fact_key(remote, subdir, ref):
    """Facts identity of one git-sourced module: remote, module inside it, and ref as written."""
    return "git:{}//{}@{}".format(remote, subdir, ref)

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

def _git_pool_key(remote, pin):
    """Identity of one git checkout, which is also its repository name.

    `pin` is the commit for a checkout made with git, where a tag and the
    id it names are one checkout, and the ref as written for a GitHub
    archive, where a tag's commit is never learned.
    """
    return "rt_git_{}_{}".format(_remote_name(remote), pin[:12] if is_commit(pin) else _sanitize_name(pin))

def _claim_target(modules, source, subdir):
    """The target inside a pool repository that serves `source`, creating it if new.

    The init aspect matches a git module by its source verbatim, so every
    spelling that reaches one checkout gets its own target, and two
    spellings of one subdir cannot share a target name.
    """
    if source not in modules:
        base = module_target_name(subdir)
        taken = [entry["target"] for entry in modules.values()]
        target = base
        for n in range(2, len(taken) + 3):
            if target not in taken:
                break
            target = "{}_{}".format(base, n)
        modules[source] = {"subdir": subdir, "target": target}
    return modules[source]["target"]

def _module_refs(module_ctx, root, subdir):
    """The external references of the module at `subdir` under an unpacked `root`."""
    start_path = root
    for segment in subdir.split("/"):
        if segment:
            start_path = start_path.get_child(segment)
    return [
        {"source": ref.source, "version": ref.version}
        for ref in _external_refs(module_ctx, start_path, root)
    ]

def _resolve_git(module_ctx, source, git, constraint, existing_facts, new_facts, pool, checkouts):
    """Resolve one git-sourced reference to a pool target.

    A GitHub `https` remote is fetched as an archive and pinned by its
    integrity; any other remote is checked out with git and pinned by
    commit. Either way the ref has to be a tag or a full commit id: a
    branch moves, and nothing built from one is reproducible.

    Args:
        module_ctx: (module_ctx) The extension context.
        source: (str) The `module` block's source, verbatim.
        git: (struct) `parse_git_source(source)`.
        constraint: (str) The block's `version`, which must be empty.
        existing_facts: (Facts|None) The previous eval's facts.
        new_facts: (dict) This eval's facts, mutated in place.
        pool: (dict) The shared module pool, mutated in place.
        checkouts: (dict) Memo for the fetchers, mutated in place.

    Returns:
        (tuple[str, list[dict]]) The pool target's label and the module's
        own external references, as `{"source", "version"}` dicts.
    """
    if constraint:
        fail(("module source {} is fetched from git and cannot carry version = {}. " +
              "Pin a git module with `?ref=` in its source instead.").format(source, repr(constraint)))
    if not git.ref:
        fail(("module source {} names no `?ref=`. A git module is pinned to a tag or a full " +
              "commit id; the remote's default branch is not accepted.").format(source))

    key = _git_fact_key(git.remote, git.subdir, git.ref)
    cached = existing_facts[key] if existing_facts != None and key in existing_facts else None
    if type(cached) != "dict" or "deps" not in cached:
        cached = None

    if _is_github_https(git.remote):
        if cached and cached.get("url") and cached.get("integrity"):
            new_facts[key] = cached
            entry = {
                "integrity": cached["integrity"],
                "kind": "verbatim_archive",
                "modules": {},
                "strip_prefix": cached["strip_prefix"],
                "url": cached["url"],
            }
            deps = cached["deps"]
        else:
            archive = _fetch_github_archive(module_ctx, git.remote, git.ref, checkouts)
            deps = _module_refs(module_ctx, archive.path, git.subdir)
            new_facts[key] = {
                "deps": deps,
                "integrity": archive.integrity,
                "strip_prefix": archive.strip_prefix,
                "url": archive.url,
            }
            entry = {
                "integrity": archive.integrity,
                "kind": "verbatim_archive",
                "modules": {},
                "strip_prefix": archive.strip_prefix,
                "url": archive.url,
            }
        pool_key = _git_pool_key(git.remote, git.ref)
    else:
        if cached and cached.get("commit"):
            new_facts[key] = cached
            commit = cached["commit"]
            deps = cached["deps"]
        else:
            checkout = _fetch_git(module_ctx, git.remote, git.ref, checkouts)
            commit = checkout.commit
            deps = _module_refs(module_ctx, checkout.path, git.subdir)
            new_facts[key] = {"commit": commit, "deps": deps}
        entry = {
            "commit": commit,
            "kind": "git",
            "modules": {},
            "remote": git.remote,
        }
        pool_key = _git_pool_key(git.remote, commit)

    if pool_key not in pool:
        pool[pool_key] = entry
    target = _claim_target(pool[pool_key]["modules"], source, git.subdir)
    return "@{}//:{}".format(pool_key, target), deps

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
        if not _is_external(block.source):
            continue
        if _ref_key(block.source, block.version) in queued:
            continue
        queued[_ref_key(block.source, block.version)] = True
        pending.append((block.source, block.version, block.key))

    members = []
    resolved = {}

    # Archive per `(source-without-subdir, version)`, not per reference: two
    # `//subdir` references into one module are two repos cut from one
    # download. Likewise one checkout per git `(remote, ref)`.
    archives = {}
    checkouts = {}

    for _ in range(_MAX_REGISTRY_MODULES):
        if not pending:
            break

        # Breadth first, so the root module's own blocks are all resolved
        # before anything found inside a fetched module: a constraint written
        # by the user is resolved before one written by a dependency.
        source, constraint, _ = pending.pop(0)

        git = parse_git_source(source)
        if git != None:
            if source in resolved:
                continue
            resolved[source] = True
            member, deps = _resolve_git(module_ctx, source, git, constraint, existing_facts, new_facts, pool, checkouts)
            for dep in deps:
                if _ref_key(dep["source"], dep["version"]) in queued:
                    continue
                queued[_ref_key(dep["source"], dep["version"])] = True
                pending.append((dep["source"], dep["version"], ""))
            members.append(member)
            continue

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
                for ref in _external_refs(module_ctx, start_path, archive.path)
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
                "kind": "archive",
                "strip_prefix": strip_prefix,
                "subdirs": {},
                "url": archive_url,
                "version": version,
            }
        pool[pool_key]["subdirs"][subdir] = True
        members.append("@{}//:{}".format(pool_key, module_target_name(subdir)))

    if pending:
        fail("`{}` pulls in more than {} distinct external modules".format(
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
    """Declare one repository per entry of the pool built by `resolve_registry_modules`.

    Args:
        pool: (dict) Pool repository name → archive or checkout dict.
    """
    for repo_name, entry in pool.items():
        if entry["kind"] == "verbatim_archive":
            terraform_archive_module_repository(
                name = repo_name,
                url = entry["url"],
                integrity = entry["integrity"],
                strip_prefix = entry["strip_prefix"],
                modules = [
                    {"source": source, "subdir": module["subdir"], "target": module["target"]}
                    for source, module in sorted(entry["modules"].items())
                ],
            )
            continue
        if entry["kind"] == "git":
            terraform_git_module_repository(
                name = repo_name,
                remote = entry["remote"],
                commit = entry["commit"],
                modules = [
                    {"source": source, "subdir": module["subdir"], "target": module["target"]}
                    for source, module in sorted(entry["modules"].items())
                ],
            )
            continue
        terraform_module_repository(
            name = repo_name,
            source = entry["base_source"],
            version = entry["version"],
            url = entry["url"],
            integrity = entry["integrity"],
            strip_prefix = entry["strip_prefix"],
            subdirs = sorted(entry["subdirs"].keys()),
        )
