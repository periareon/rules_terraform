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

def _registry_lookup(module_ctx, registry, provider_source, version, os_name, arch):
    """Fetch the download URL and hex SHA256 for a provider archive.

    Uses the Terraform Registry v1 provider download endpoint, which is
    supported by both `registry.terraform.io` and `registry.opentofu.org`.
    Returns (url, sha256_hex) on success, or (None, None) if the provider
    isn't available for the requested platform.
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
        return None, None

    payload = json.decode(module_ctx.read(output))
    download_url = payload.get("download_url")
    shasum = payload.get("shasum")
    if not download_url or not shasum:
        return None, None
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

def _lookup_cached(module_ctx, registry, provider, os_name, arch, existing_facts, new_facts):
    """`_registry_lookup`, memoized through `module_ctx.facts` when available.

    Where a published provider version's archive lives, and whether it exists
    for a platform at all, does not change after publication. Remembering the
    answer is what keeps a `.tf` edit anywhere in the workspace from costing
    five registry round trips per provider.

    Returns `(url, sha256)`, both `None` when the provider is not published
    for the platform.
    """
    platform = "{}_{}".format(os_name, arch)
    key = _provider_fact_key(registry, provider.source, provider.version, platform)
    if existing_facts != None and key in existing_facts:
        cached = existing_facts[key]
        if new_facts != None:
            new_facts[key] = cached
        return (cached["url"] or None, cached["sha256"] or None)

    url, shasum = _registry_lookup(
        module_ctx = module_ctx,
        registry = registry,
        provider_source = provider.source,
        version = provider.version,
        os_name = os_name,
        arch = arch,
    )
    if new_facts != None:
        new_facts[key] = {"sha256": shasum or "", "url": url or ""}
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
            for the next one. Entries are keyed per (registry, provider,
            version, platform).

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

        resolved_platforms = []
        for os_name, arch in platforms:
            platform_str = "{os}_{arch}".format(os = os_name, arch = arch)
            url, shasum = _lookup_cached(
                module_ctx,
                provider_registry,
                provider,
                os_name,
                arch,
                existing_facts,
                new_facts,
            )
            if not url:
                # Provider is not published for this platform. Skip it; the
                # generated select() simply won't have a case for this
                # constraint set. Users on that platform will get a clear
                # "no matching toolchain" error rather than a bogus download.
                continue

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

        # Not found for any platform is not "an unusual provider", it is a
        # lookup that is not working: a typo in the lock, a registry that is
        # down, or an entry that belongs to a registry we were not told
        # about. Left alone it would surface much later, at `terraform init`,
        # as a provider the module never installed.
        if not resolved_platforms:
            fail(
                ("provider {source} {version} (from {lock}) could not be resolved on {registry} " +
                 "for any of: {platforms}.\n" +
                 "Check that the registry is reachable and that the lock entry's host and " +
                 "source are the ones the provider is published under.").format(
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
