"""The `toolchain` half of the `terraform` and `tofu` extensions.

`declare_toolchains` materializes one hub repository declaring a toolchain
per platform for one release, and the engine's CLI hub. The release is
the root module's `toolchain` tag, else the newest shipped in
`//<engine>/private:versions.bzl`. A build has one engine version;
nothing selects among several.

A shipped release comes with its checksums. For any other release the
extension reads the release's `SHA256SUMS` file once, records the
checksums as facts in `MODULE.bazel.lock`, and never asks again, so a
module that pins an older engine needs no change to rules_terraform and
a repository with the lockfile enabled needs no network to re-evaluate.

Per-platform archives are lazy; only the resolved platform is fetched.
"""

load(":cli.bzl", "cli_hub")
load(":platforms.bzl", "PLATFORM_TO_CONSTRAINTS")
load(":semver.bzl", "parse_version")
load(":toolchain_repo.bzl", "terraform_toolchain_repository", "terraform_toolchain_repository_hub")

visibility(["//engine/...", "//terraform/...", "//tofu/..."])

def _parse_sha256sums(content, version, archive_prefix):
    """Map `<os>_<arch>` to the hex sha256 of its zip, from a SHA256SUMS file.

    Lines look like `<hex>  terraform_1.9.8_linux_amd64.zip`; anything that
    is not a zip for a platform this ruleset knows is ignored.
    """
    prefix = "{}_{}_".format(archive_prefix, version)
    out = {}
    for line in content.splitlines():
        # `<hex>  <file>`: two spaces in the GNU coreutils format, so split on
        # spaces and drop the empty field between them.
        parts = [part for part in line.strip().split(" ") if part]
        if len(parts) != 2:
            continue
        digest, filename = parts
        if not filename.startswith(prefix) or not filename.endswith(".zip"):
            continue
        platform = filename[len(prefix):-len(".zip")]
        if platform in PLATFORM_TO_CONSTRAINTS:
            out[platform] = digest
    return out

def _checksums_for(module_ctx, engine, version, sha256sums_url, archive_prefix, existing_facts, new_facts):
    """The per-platform checksums of a release not in the shipped table."""
    fact_key = "{}@{}".format(engine, version)
    cached = existing_facts[fact_key] if existing_facts != None and fact_key in existing_facts else None
    if type(cached) == "dict" and cached:
        new_facts[fact_key] = cached
        return cached

    url = sha256sums_url(version)
    output = "{}_{}_SHA256SUMS".format(engine, version)
    result = module_ctx.download(url = url, output = output, allow_fail = True)
    if not result.success:
        fail("{} {} is not a release this ruleset ships checksums for, and its checksum file could not be fetched from {}".format(
            engine,
            version,
            url,
        ))
    checksums = _parse_sha256sums(module_ctx.read(output), version, archive_prefix)
    if not checksums:
        fail("{} lists no archives for {} {} on a supported platform".format(url, engine, version))
    new_facts[fact_key] = checksums
    return checksums

def declare_toolchains(module_ctx, *, config, existing_facts, new_facts):
    """Declare the toolchain repositories for the release the build uses.

    Materializes `@<name>_toolchains`, one repository per platform of the
    root module's release, and the `@<cli_hub>` CLI hub. Called by
    `run_extension`, which owns the facts and the extension metadata.

    Args:
        module_ctx: (module_ctx) The extension context.
        config: (struct) The engine's `engine_config`.
        existing_facts: (dict|None) `module_ctx.facts` from the previous
            evaluation, or None where Bazel has no facts.
        new_facts: (dict) Mutated in place: the checksums of a release
            outside the shipped table, fetched once.
    """
    engine = config.name
    hub_name = "{}_toolchains".format(engine)
    versions = config.versions
    default_version = config.default_version
    sha256sums_url = config.sha256sums_url
    download_url = config.download_url
    archive_prefix = config.archive_prefix

    # The root module's tag picks the release; a tag in any other module is
    # that module's business, not this build's.
    version = None
    for mod in module_ctx.modules:
        if not mod.is_root:
            continue
        for tag in mod.tags.toolchain:
            if parse_version(tag.version) == None:
                fail("{}.toolchain: {} is not a version".format(engine, repr(tag.version)))
            if version != None and version != tag.version:
                fail("the root module asks for two {} versions: {} and {}".format(engine, version, tag.version))
            version = tag.version
    if version == None:
        version = default_version

    # Platform → {url, integrity|sha256} for that one release.
    if version in versions:
        platforms = {
            platform: struct(url = info["url"], integrity = info["integrity"], sha256 = "")
            for platform, info in versions[version].items()
        }
    else:
        checksums = _checksums_for(module_ctx, engine, version, sha256sums_url, archive_prefix, existing_facts, new_facts)
        platforms = {
            platform: struct(url = download_url(version, platform), integrity = "", sha256 = digest)
            for platform, digest in checksums.items()
        }

    toolchain_names = []
    toolchain_labels = {}
    exec_compatible_with = {}
    for platform, info in platforms.items():
        if platform not in PLATFORM_TO_CONSTRAINTS:
            continue
        repo_name = "{}_{}_{}".format(hub_name, version.replace(".", "_"), platform.replace("-", "_"))
        terraform_toolchain_repository(
            name = repo_name,
            version = version,
            platform = platform,
            url = info.url,
            integrity = info.integrity,
            sha256 = info.sha256,
            binary_name = config.binary_name,
            hub_bzl = config.hub_bzl,
        )
        toolchain_names.append(repo_name)
        toolchain_labels[repo_name] = "@" + repo_name
        exec_compatible_with[repo_name] = PLATFORM_TO_CONSTRAINTS[platform]

    terraform_toolchain_repository_hub(
        name = hub_name,
        toolchain_labels = toolchain_labels,
        toolchain_names = toolchain_names,
        exec_compatible_with = exec_compatible_with,
        target_compatible_with = {},
        toolchain_type = config.toolchain_type,
    )

    cli_hub(
        name = config.cli_hub,
        hub_bzl = config.hub_bzl,
        rule_name = "{}_cli".format(engine),
        target_name = config.cli_hub,
    )

def toolchain_tag_class(engine):
    """The `toolchain` tag class of an engine's extension.

    Args:
        engine: (str) Engine name for the docs.

    Returns:
        (tag_class)
    """
    return tag_class(
        doc = """Pins the {engine} release the build uses. Root module only,
        at most one; without it the build uses the newest release shipped
        in `//{engine}/private:versions.bzl`. Tags in other modules are
        ignored. For a release outside the shipped table the extension
        fetches the release's `SHA256SUMS` once and records the checksums
        as facts in `MODULE.bazel.lock`.""".format(engine = engine),
        attrs = {
            "version": attr.string(
                doc = "The release, e.g. `1.9.8`.",
                mandatory = True,
            ),
        },
    )
