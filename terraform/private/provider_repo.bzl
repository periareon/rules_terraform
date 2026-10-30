"""Terraform provider repository configuration.

Provider archives live in a pool shared by every `deps` hub: one repository
per (registry, provider, version, platform), named from that identity alone.
A hub (`deps_hub.bzl`) is an alias layer over the pool plus the lock file,
so two root modules whose locks agree on a provider version fetch and
extract it once.

Provider archives are looked up via the Terraform Registry v1 provider download
API. This works for any namespace, not just `hashicorp/*`, and delivers a
platform-specific `download_url` + hex `shasum` for the archive in a single
request. That URL may point to `releases.hashicorp.com`, GitHub releases, S3,
etc. — whatever the provider publisher configured.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(":lock_hcl.bzl", "parse_lock_file")

DEFAULT_REGISTRY = "registry.terraform.io"

_PROVIDER_REPO_TERRAFORM_PROVIDER = """\
terraform_provider(
    name = "provider",
    source = "{source}",
    version = "{version}",
    platform = "{platform}",
    # Include every file the provider archive shipped with (binary + LICENSE +
    # any other data). Terraform's `h1:` (PackageHashV1) hashes the entire
    # provider directory; leaving any file out makes our install diverge from
    # what real `terraform init` would produce.
    files = glob(
        ["**/*"],
        exclude = ["BUILD.bazel", "REPO.bazel", "WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel"],
    ),
    visibility = ["//visibility:public"],
)
"""

_PROVIDER_REPO_BUILD_FILE = """\
load("@rules_terraform//terraform/private:terraform.bzl", "terraform_provider")

{terraform_provider}
"""

def _terraform_provider_build_file_content(provider_source, version, platform):
    _, name = provider_source.split("/", 1)
    return _PROVIDER_REPO_BUILD_FILE.format(
        terraform_provider = _PROVIDER_REPO_TERRAFORM_PROVIDER.format(
            source = provider_source,
            version = version,
            platform = platform,
            name = name,
        ),
    )

def _fail_lookup(what, provider_source, version, registry, url, detail):
    fail(
        ("could not look up {what} for provider {source} {version} on {registry}: {detail}\n" +
         "URL: {url}\n" +
         "Check that the registry is reachable from this machine and that the lock entry's " +
         "host and source are the ones the provider is published under.").format(
            what = what,
            source = provider_source,
            version = version,
            registry = registry,
            detail = detail,
            url = url,
        ),
    )

def _registry_platforms(module_ctx, registry, provider_source, version):
    """The platforms the registry publishes `version` of a provider for.

    Uses the Registry v1 `versions` endpoint, which both
    `registry.terraform.io` and `registry.opentofu.org` implement. Fails if
    the registry cannot be reached or does not list the version: a lock entry
    naming a version the registry has never heard of is a lookup that is not
    working, not an unusual provider.

    Returns:
        (list[str]) Sorted `<os>_<arch>` strings.
    """
    namespace, name = provider_source.split("/", 1)
    url = "https://{registry}/v1/providers/{namespace}/{name}/versions".format(
        registry = registry,
        namespace = namespace,
        name = name,
    )
    output = "registry_{namespace}_{name}_versions.json".format(
        namespace = namespace.replace("/", "_"),
        name = name.replace("/", "_"),
    )
    result = module_ctx.download(url = url, output = output, allow_fail = True)
    if not result.success:
        _fail_lookup("published platforms", provider_source, version, registry, url, "the request failed")

    payload = json.decode(module_ctx.read(output), default = None)
    entries = payload.get("versions") if type(payload) == "dict" else None
    if type(entries) != "list":
        _fail_lookup("published platforms", provider_source, version, registry, url, "the response is not a versions list")

    for entry in entries:
        if type(entry) != "dict" or entry.get("version") != version:
            continue
        platforms = [
            "{}_{}".format(platform["os"], platform["arch"])
            for platform in entry.get("platforms", [])
            if type(platform) == "dict" and platform.get("os") and platform.get("arch")
        ]
        if not platforms:
            _fail_lookup("published platforms", provider_source, version, registry, url, "the registry lists the version with no platforms")
        return sorted(platforms)

    _fail_lookup("published platforms", provider_source, version, registry, url, "the registry does not list this version")
    return None

def _registry_lookup(module_ctx, registry, provider_source, version, os_name, arch):
    """Fetch the download URL and hex SHA256 for a provider archive.

    Uses the Terraform Registry v1 provider download endpoint, which is
    supported by both `registry.terraform.io` and `registry.opentofu.org`.
    Only called for a platform the registry's own versions list says is
    published, so there is no benign reason for it to fail: any failure is
    reported and stops the evaluation rather than being read as "not
    available", which would record the gap in `MODULE.bazel.lock` and never
    retry it.

    Returns:
        (tuple[str, str]) `(url, sha256_hex)`.
    """
    namespace, name = provider_source.split("/", 1)
    url = "https://{registry}/v1/providers/{namespace}/{name}/{version}/download/{os}/{arch}".format(
        registry = registry,
        namespace = namespace,
        name = name,
        version = version,
        os = os_name,
        arch = arch,
    )
    output = "registry_{namespace}_{name}_{version}_{os}_{arch}.json".format(
        namespace = namespace.replace("/", "_"),
        name = name.replace("/", "_"),
        version = version,
        os = os_name,
        arch = arch,
    )
    result = module_ctx.download(
        url = url,
        output = output,
        allow_fail = True,
    )
    if not result.success:
        _fail_lookup("the archive location", provider_source, version, registry, url, "the request failed")

    payload = json.decode(module_ctx.read(output), default = None)
    download_url = payload.get("download_url") if type(payload) == "dict" else None
    shasum = payload.get("shasum") if type(payload) == "dict" else None
    if not download_url or not shasum:
        _fail_lookup("the archive location", provider_source, version, registry, url, "the response carries no download_url and shasum")
    return download_url, shasum

def terraform_provider_repository(*, name, provider_source, version, platform, url, sha256):
    """Register an http_archive for a single provider/platform combination."""
    http_archive(
        name = name,
        urls = [url],
        sha256 = sha256,
        build_file_content = _terraform_provider_build_file_content(provider_source, version, platform),
    )
    return name

def _provider_fact_key(registry, source, version, platform):
    return "provider:{}/{}@{}:{}".format(registry, source, version, platform)

def _platforms_fact_key(registry, source, version):
    return "provider-platforms:{}/{}@{}".format(registry, source, version)

def _recall(key, existing_facts, new_facts):
    """A fact by key: from this evaluation first, then the previous one.

    Consulting `new_facts` first is what lets two hubs that lock the same
    provider version share one lookup on the evaluation that first sees it.
    A fact found in `existing_facts` is carried into `new_facts`, since Bazel
    keeps only what this evaluation returns.
    """
    if new_facts != None and key in new_facts:
        return new_facts[key]
    if existing_facts != None and key in existing_facts:
        if new_facts != None:
            new_facts[key] = existing_facts[key]
        return existing_facts[key]
    return None

def _remember(key, value, new_facts):
    if new_facts != None:
        new_facts[key] = value
    return value

def _cached_archive(registry, provider, platform, existing_facts, new_facts):
    """The recorded `(url, sha256)` for one provider archive, or None.

    Older evaluations recorded a platform the lookup failed for as an entry
    with empty strings, which made a transient failure permanent. Such an
    entry is treated as absent, so it is looked up again and not carried
    forward.
    """
    key = _provider_fact_key(registry, provider.source, provider.version, platform)
    cached = _recall(key, existing_facts, new_facts)
    if type(cached) != "dict" or not cached.get("url") or not cached.get("sha256"):
        if new_facts != None:
            new_facts.pop(key, None)
        return None
    return cached["url"], cached["sha256"]

def _published_platforms(module_ctx, registry, provider, existing_facts, new_facts):
    """`_registry_platforms`, memoized through `module_ctx.facts`.

    Which platforms a published provider version exists for does not change
    after publication. It is only consulted to justify leaving a platform
    out: a platform with a recorded archive is known to be published without
    it, so a provider published for every default platform never needs this
    fact at all.
    """
    key = _platforms_fact_key(registry, provider.source, provider.version)
    cached = _recall(key, existing_facts, new_facts)
    if type(cached) == "dict" and type(cached.get("platforms")) == "list" and cached["platforms"]:
        return cached["platforms"]
    platforms = _registry_platforms(module_ctx, registry, provider.source, provider.version)
    _remember(key, {"platforms": platforms}, new_facts)
    return platforms

def _lookup_archive(module_ctx, registry, provider, os_name, arch, existing_facts, new_facts):
    """`_registry_lookup`, memoized through `module_ctx.facts` when available.

    Where a published provider version's archive lives does not change after
    publication. Remembering the answer is what keeps a `.tf` edit anywhere
    in the workspace from costing five registry round trips per provider.

    Returns:
        (tuple[str, str]) `(url, sha256)`.
    """
    platform = "{}_{}".format(os_name, arch)
    cached = _cached_archive(registry, provider, platform, existing_facts, new_facts)
    if cached != None:
        return cached

    url, shasum = _registry_lookup(
        module_ctx = module_ctx,
        registry = registry,
        provider_source = provider.source,
        version = provider.version,
        os_name = os_name,
        arch = arch,
    )
    key = _provider_fact_key(registry, provider.source, provider.version, platform)
    _remember(key, {"sha256": shasum, "url": url}, new_facts)
    return url, shasum

def _check_against_lock(provider, platform, shasum, lock_file_path):
    """Refuse an archive the lock file does not vouch for.

    The lock's `zh:` entries are the SHA-256 of each platform's release
    archive, recorded when the lock was written. The registry's answer today
    has to be one of them; otherwise the lock is not pinning anything and the
    registry is being trusted at every evaluation.
    """
    zh_hashes = [h for h in provider.hashes if h.startswith("zh:")]
    if not zh_hashes:
        # A lock with no archive hashes (a hand-written entry, say) has
        # nothing to check against. The `h1:` hash is still verified by the
        # engine against the installed directory.
        return
    if "zh:" + shasum not in zh_hashes:
        fail(
            ("provider {source} {version} for {platform}: the registry reports archive " +
             "sha256 {shasum}, which is not among the zh: hashes in {lock}.\n" +
             "Either the lock file is stale for this platform (regenerate it by `bazel run`ning " +
             "the module's terraform_providers_lock / tofu_providers_lock target, which " +
             "covers {platform}) or the registry is serving a different archive than the one " +
             "that was locked.").format(
                source = provider.source,
                version = provider.version,
                platform = platform,
                shasum = shasum,
                lock = lock_file_path,
            ),
        )

def _pool_repo_name(registry, source, version, platform):
    """Name of the pool repository holding one provider archive.

    Built from the archive's identity and nothing else, so every hub that
    locks the same provider version lands on the same repository. The
    registry is part of the identity: `registry.opentofu.org` serves its own
    builds of the hashicorp providers, which are different archives from the
    ones on `registry.terraform.io`.
    """
    return "rt_prov_{}_{}_{}_{}".format(registry, source.replace("/", "_"), version, platform)

def resolve_providers_from_lock_file(
        module_ctx,
        lock_file_path,
        pool,
        registry = DEFAULT_REGISTRY,
        platforms = None,
        existing_facts = None,
        new_facts = None):
    """Resolve a lock file's providers into the shared pool.

    Nothing is declared here. Every hub is resolved first and the pool is
    declared once afterwards by `declare_provider_pool`, which is what lets
    two locks pinning the same provider share one fetched archive.

    Args:
        module_ctx: (module_ctx) The module extension context.
        lock_file_path: (Label) A label pointing at a `.terraform.lock.hcl` file.
        pool: (dict) Shared across hubs, mutated in place. Maps pool
            repository name to the archive it holds.
        registry: (str) Registry hostname (defaults to
            `registry.terraform.io`). A provider whose lock entry names a
            different host is looked up on that host instead.
        platforms: (list[tuple[str, str]]) Optional list of (os, arch)
            tuples. Defaults to the common five.
        existing_facts: (Facts|None) The previous evaluation's
            `module_ctx.facts`, consulted before any registry call.
        new_facts: (dict|None) Where to record this evaluation's lookups
            for the next one. One entry per (registry, provider, version,
            platform) archive, plus one per (registry, provider, version)
            listing its published platforms where that was needed to
            leave a platform out.

    Returns:
        (dict[tuple[str, str], str]) Mapping (provider_source,
        platform_str) → pool repository name, for the hub to alias.
    """
    providers = parse_lock_file(module_ctx.read(lock_file_path))

    if platforms == None:
        platforms = [
            ("linux", "amd64"),
            ("linux", "arm64"),
            ("darwin", "amd64"),
            ("darwin", "arm64"),
            ("windows", "amd64"),
        ]

    provider_repos = {}

    for provider in providers:
        # The lock says where each provider came from. A private registry
        # entry is not findable on the public one, and silently looking there
        # would turn into a hub with that provider missing.
        provider_registry = provider.host if provider.host else registry

        # A platform is left out only on the registry's word that the version
        # was never published for it. Any other reason a lookup could come up
        # empty, a registry outage or a typo in the lock, is an error here
        # and now, not a thinner hub that fails for someone else later.
        published = None
        resolved_platforms = []
        for os_name, arch in platforms:
            platform_str = "{os}_{arch}".format(os = os_name, arch = arch)
            if _cached_archive(provider_registry, provider, platform_str, existing_facts, new_facts) == None:
                if published == None:
                    published = _published_platforms(
                        module_ctx,
                        provider_registry,
                        provider,
                        existing_facts,
                        new_facts,
                    )
                if platform_str not in published:
                    # The generated select() simply has no case for this
                    # platform; a build there gets a clear "no matching
                    # toolchain" error rather than a bogus download.
                    continue

            url, shasum = _lookup_archive(
                module_ctx,
                provider_registry,
                provider,
                os_name,
                arch,
                existing_facts,
                new_facts,
            )

            _check_against_lock(provider, platform_str, shasum, lock_file_path)
            resolved_platforms.append(platform_str)

            repo_name = _pool_repo_name(provider_registry, provider.source, provider.version, platform_str)
            if repo_name in pool:
                # Another lock already brought this archive in. Two locks
                # agreeing on a version is the common case in a monorepo, and
                # the whole point of the pool; disagreeing on its hash is
                # not possible, since both were checked against the same
                # registry answer above.
                pass
            else:
                pool[repo_name] = struct(
                    provider_source = provider.source,
                    version = provider.version,
                    platform = platform_str,
                    url = url,
                    sha256 = shasum,
                )
            provider_repos[(provider.source, platform_str)] = repo_name

        # Published, but for none of the platforms asked for. Left alone it
        # would surface much later, at `terraform init`, as a provider the
        # module never installed.
        if not resolved_platforms:
            fail(
                ("provider {source} {version} (from {lock}) is not published on {registry} " +
                 "for any of: {platforms}.").format(
                    source = provider.source,
                    version = provider.version,
                    lock = lock_file_path,
                    registry = provider_registry,
                    platforms = ", ".join(["{}_{}".format(o, a) for o, a in platforms]),
                ),
            )

    return provider_repos

def declare_provider_pool(pool):
    """Declare one `http_archive` per entry of the pool.

    The pool is built by `resolve_providers_from_lock_file`, once every hub
    has been resolved.

    Args:
        pool: (dict) Pool repository name → archive struct.
    """
    for repo_name, entry in pool.items():
        terraform_provider_repository(
            name = repo_name,
            provider_source = entry.provider_source,
            version = entry.version,
            platform = entry.platform,
            url = entry.url,
            sha256 = entry.sha256,
        )
