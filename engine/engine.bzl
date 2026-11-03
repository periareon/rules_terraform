"""The configuration one engine hands to the shared rules.

`//terraform` and `//tofu` each build one `engine_config` and pass it to
`make_engine_rules` and `run_extension`. Wherever
the shared code would otherwise need to know an engine's name, registry or
release location, it reads a field of this struct instead, so adding or
changing an engine is a change to its own directory only.
"""

visibility(["//engine/...", "//terraform/...", "//tofu/..."])

def engine_config(
        *,
        name,
        toolchain_type,
        version_flag,
        hub_bzl,
        cli_hub,
        registry,
        source_extensions,
        versions,
        default_version,
        binary_name,
        archive_prefix,
        sha256sums_url,
        download_url,
        format_ignore_tags,
        validate_ignore_tags):
    """Describe one engine.

    Args:
        name: (str) The engine's name, `terraform` or `tofu`. Names the
            `<name>_fmt_checks` / `<name>_validate_checks` output groups,
            action mnemonics, generated file names and lock facts.
        toolchain_type: (str) Label of the engine's `toolchain_type`.
        version_flag: (str) Label of the engine's `settings:version` flag.
        hub_bzl: (str) Label of the public `.bzl` file the repositories the
            extensions generate (toolchains, provider and module pools, deps
            hubs, the CLI hub) load their rules from. Engine code is not
            loadable from outside `//terraform` and `//tofu`, so each engine
            re-exports what those repositories need.
        cli_hub: (str) Name of the CLI hub repository, `@<cli_hub>`.
        registry: (str) Registry a `deps` tag that names none resolves
            against.
        source_extensions: (list[str]) File extensions the engine loads as
            configuration, e.g. `.tf`. A `<name>_module` rejects any other
            file in `srcs` at analysis time, so a file the engine would
            silently ignore is an error instead.
        versions: (dict) Shipped releases: version → platform → `{url, integrity}`.
        default_version: (str) The release used when neither a `version` tag
            nor the flag picks one.
        binary_name: (str) Executable name inside a release archive.
        archive_prefix: (str) Archive file name prefix in `SHA256SUMS`.
        sha256sums_url: (function) version → URL of the release's `SHA256SUMS`.
        download_url: (function) (version, platform) → archive URL.
        format_ignore_tags: (list[str]) Tags that skip this engine's fmt
            aspect only; `no_format` and friends skip every engine's.
        validate_ignore_tags: (list[str]) Tags that skip this engine's
            validate aspect only.

    Returns:
        (struct) The configuration, one field per argument.
    """
    return struct(
        name = name,
        toolchain_type = toolchain_type,
        version_flag = version_flag,
        hub_bzl = hub_bzl,
        cli_hub = cli_hub,
        registry = registry,
        source_extensions = source_extensions,
        versions = versions,
        default_version = default_version,
        binary_name = binary_name,
        archive_prefix = archive_prefix,
        sha256sums_url = sha256sums_url,
        download_url = download_url,
        format_ignore_tags = format_ignore_tags,
        validate_ignore_tags = validate_ignore_tags,
    )
