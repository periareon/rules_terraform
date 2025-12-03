"""Terraform provider repository configuration.

Provider archives are looked up via the Terraform Registry v1 provider download
API. This works for any namespace, not just `hashicorp/*`, and delivers a
platform-specific `download_url` + hex `shasum` for the archive in a single
request. That URL may point to `releases.hashicorp.com`, GitHub releases, S3,
etc. — whatever the provider publisher configured.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(":lock_hcl.bzl", "parse_lock_file")
load(":toolchain_repo.bzl", "PLATFORM_TO_CONSTRAINTS")
load(":util.bzl", "strip_canonical_repo_prefix")

DEFAULT_REGISTRY = "registry.terraform.io"

_PROVIDER_HUB_PROVIDER_GROUP = """load("@rules_terraform//terraform/private:terraform.bzl", "terraform_provider_group")

terraform_provider_group(
    name = "{hub_name}",
    deps = [
{provider_deps}
    ],
    lock = "{lock_file}",
    visibility = ["//visibility:public"],
)
"""

_PROVIDER_HUB_BUILD_FILE = """\"\"\"Provider hub for {hub_name}\"\"\"

{provider_group}
"""

_PROVIDER_SUBPACKAGE_BUILD_FILE = """alias(
    name = "{target_name}",
    actual = select({{
{select_cases}
    }}),
    visibility = ["//visibility:public"],
)
"""

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

def terraform_providers_from_lock_file(module_ctx, lock_file_path, hub_name, registry = DEFAULT_REGISTRY, platforms = None):
    """Parse a lock file and register repositories for every provider/platform.

    Args:
        module_ctx: (module_ctx) The module extension context.
        lock_file_path: (Label) A label pointing at a `.terraform.lock.hcl` file.
        hub_name: (str) Prefix for the generated repository names.
        registry: (str) Registry hostname (defaults to
            `registry.terraform.io`).
        platforms: (list[tuple[str, str]]) Optional list of (os, arch)
            tuples. Defaults to the common four.

    Returns:
        (dict[tuple[str, str], str]) Mapping (provider_source,
        platform_str) → repository name.
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
        namespace = provider.source.split("/")[0]
        provider_name = provider.source.split("/")[1]
        provider_sanitized = "{namespace}_{name}".format(
            namespace = namespace,
            name = provider_name.replace("-", "_"),
        )

        for os_name, arch in platforms:
            platform_str = "{os}_{arch}".format(os = os_name, arch = arch)
            url, shasum = _registry_lookup(
                module_ctx = module_ctx,
                registry = registry,
                provider_source = provider.source,
                version = provider.version,
                os_name = os_name,
                arch = arch,
            )
            if not url:
                # Provider is not published for this platform. Skip it; the
                # generated select() simply won't have a case for this
                # constraint set. Users on that platform will get a clear
                # "no matching toolchain" error rather than a bogus download.
                continue

            repo_name = "{hub}_{provider}_{platform}".format(
                hub = hub_name,
                provider = provider_sanitized,
                platform = platform_str,
            )
            terraform_provider_repository(
                name = repo_name,
                provider_source = provider.source,
                version = provider.version,
                platform = platform_str,
                url = url,
                sha256 = shasum,
            )
            provider_repos[(provider.source, platform_str)] = repo_name

    return provider_repos

def _BUILD_for_provider_hub(provider_repos_str, hub_name, lock_file_path):
    providers_by_source = {}
    for key_str, repo_name in provider_repos_str.items():
        parts = key_str.split(":", 1)
        if len(parts) != 2:
            continue
        provider_source = parts[0]
        platform = parts[1]
        providers_by_source.setdefault(provider_source, []).append((platform, repo_name))

    subpackages = {}
    provider_deps_list = []
    for provider_source, platforms in providers_by_source.items():
        namespace = provider_source.split("/")[0]
        provider_name = provider_source.split("/")[1]
        subpackage_name = "{namespace}_{name}".format(
            namespace = namespace,
            name = provider_name.replace("-", "_"),
        )

        select_cases = []
        for platform, repo_name in platforms:
            if platform in PLATFORM_TO_CONSTRAINTS:
                select_cases.append(
                    '        "@rules_terraform//terraform/private/constraints:{}": "@{}//:provider",'.format(
                        platform,
                        repo_name,
                    ),
                )

        subpackages[subpackage_name] = _PROVIDER_SUBPACKAGE_BUILD_FILE.format(
            target_name = subpackage_name,
            select_cases = "\n".join(select_cases),
        )

        provider_deps_list.append("        \"//{}:{}\",".format(subpackage_name, subpackage_name))

    provider_group_content = _PROVIDER_HUB_PROVIDER_GROUP.format(
        hub_name = strip_canonical_repo_prefix(hub_name),
        provider_deps = "\n".join(provider_deps_list),
        lock_file = lock_file_path,
    )
    return _PROVIDER_HUB_BUILD_FILE.format(
        hub_name = hub_name,
        provider_group = provider_group_content,
    ), subpackages

def _terraform_provider_hub_impl(repository_ctx):
    repository_ctx.file("WORKSPACE.bazel", """workspace(name = "{}")""".format(
        repository_ctx.name,
    ))
    repository_ctx.file(".terraform.lock.hcl", repository_ctx.read(repository_ctx.attr.lock_file_label))

    root_build_content, subpackages = _BUILD_for_provider_hub(
        provider_repos_str = repository_ctx.attr.provider_repos,
        hub_name = repository_ctx.name,
        lock_file_path = ".terraform.lock.hcl",
    )
    repository_ctx.file("BUILD.bazel", root_build_content)
    for subpackage_name, subpackage_build_content in subpackages.items():
        repository_ctx.file("{}/BUILD.bazel".format(subpackage_name), subpackage_build_content)

terraform_provider_hub = repository_rule(
    doc = "Generates a provider hub repository that aggregates provider repositories.",
    attrs = {
        "lock_file_label": attr.label(
            doc = "Label to the lock file in the main repository.",
            mandatory = True,
            allow_single_file = [".terraform.lock.hcl"],
        ),
        "provider_repos": attr.string_dict(
            doc = "Mapping of 'provider_source:platform' to repository name.",
            mandatory = True,
        ),
    },
    implementation = _terraform_provider_hub_impl,
)
