"""The `toolchain` half of the `terraform` and `tofu` extensions.

`declare_toolchains` materializes one hub repository declaring a toolchain
per (version, platform), and the engine's CLI hub. The versions on offer are:

* the releases shipped in `//<engine>/private:versions.bzl` — the three
  newest at the time the table was generated, with their checksums — and
* any release a `toolchain` tag asks for. For those the extension reads the
  release's `SHA256SUMS` file once, records the checksums as facts in
  `MODULE.bazel.lock`, and never asks again. A module that pins an older
  engine therefore needs no change to rules_terraform, and a repository
  with the lockfile enabled needs no network to re-evaluate.

Which version a build uses is `//<engine>/settings:version`. Left empty,
the default applies: the version the root module's `toolchain` tag marked
`default = True`, else the newest version shipped in the table. Any other
value names one of the versions above; the hub carries a `config_setting`
per version so toolchain resolution can match it.

Per-(version, platform) archives are lazy; only the resolved combination is
fetched.
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
    """Declare the toolchain repositories the `toolchain` tags ask for.

    Materializes `@<name>_toolchains`, one repository per (version, platform)
    it registers, and the `@<cli_hub>` CLI hub. Called by `run_extension`,
    which owns the facts and the extension metadata.

    Args:
        module_ctx: (module_ctx) The extension context.
        config: (struct) The engine's `engine_config`.
        existing_facts: (dict|None) `module_ctx.facts` from the previous
            evaluation, or None where Bazel has no facts.
        new_facts: (dict) Mutated in place: the checksums of every tagged
            release, fetched once.
    """
    engine = config.name
    hub_name = "{}_toolchains".format(engine)
    versions = config.versions
    default_version = config.default_version
    sha256sums_url = config.sha256sums_url
    download_url = config.download_url
    archive_prefix = config.archive_prefix

    # Every version anyone asked for, plus which one the root marked default.
    requested = {}
    default = None
    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            if parse_version(tag.version) == None:
                fail("{}.toolchain: {} is not a version".format(engine, repr(tag.version)))
            requested[tag.version] = True
            if tag.default:
                if not mod.is_root:
                    fail("{}.toolchain(default = True) is only honoured in the root module; module `{}` set it for {}".format(
                        engine,
                        mod.name,
                        tag.version,
                    ))
                if default != None and default != tag.version:
                    fail("the root module marks two {} versions as default: {} and {}".format(engine, default, tag.version))
                default = tag.version
    if default == None:
        default = default_version

    # Per-version platform → {url, integrity|sha256}.
    available = {}
    for version, platforms in versions.items():
        available[version] = {
            platform: struct(url = info["url"], integrity = info["integrity"], sha256 = "")
            for platform, info in platforms.items()
        }
    for version in requested:
        if version in available:
            continue
        checksums = _checksums_for(module_ctx, engine, version, sha256sums_url, archive_prefix, existing_facts, new_facts)
        available[version] = {
            platform: struct(url = download_url(version, platform), integrity = "", sha256 = digest)
            for platform, digest in checksums.items()
        }
    if default not in available:
        fail("{} default version {} is not shipped and no `toolchain` tag requested it".format(engine, default))

    toolchain_names = []
    toolchain_labels = {}
    exec_compatible_with = {}
    target_settings = {}
    for version in sorted(available.keys()):
        for platform, info in available[version].items():
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
            target_settings[repo_name] = [":version_" + version.replace(".", "_")]

    terraform_toolchain_repository_hub(
        name = hub_name,
        toolchain_labels = toolchain_labels,
        toolchain_names = toolchain_names,
        exec_compatible_with = exec_compatible_with,
        target_compatible_with = {},
        target_settings = target_settings,
        toolchain_type = config.toolchain_type,
        version_flag = config.version_flag,
        versions = sorted(available.keys()),
        default_version = default,
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
        doc = """Makes a {engine} release available to toolchain resolution.
        Releases shipped in `//{engine}/private:versions.bzl` need no tag.
        For any other release the extension fetches the release's
        `SHA256SUMS` once and records the checksums as facts in
        `MODULE.bazel.lock`.""".format(engine = engine),
        attrs = {
            "default": attr.bool(
                default = False,
                doc = """Use this version when `//{engine}/settings:version` is
                left empty. Root module only; at most one tag may set it.
                Without it the newest shipped release is the default.""".format(engine = engine),
            ),
            "version": attr.string(
                doc = "The release, e.g. `1.9.8`.",
                mandatory = True,
            ),
        },
    )
