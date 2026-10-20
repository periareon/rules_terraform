"""Terraform toolchain repository configuration.

Also used by `//tofu` to fetch the `tofu` binary — the helpers here are
engine-agnostic (binary_name and toolchain_type are both parameters).
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

visibility(["//terraform/...", "//tofu/..."])

_TERRAFORM_TOOLCHAIN_BUILD_FILE_CONTENT = """\
load("@rules_terraform//terraform/private:toolchain.bzl", "terraform_toolchain")

filegroup(
    name = "terraform_bin",
    srcs = ["{terraform_bin}"],
    data = glob(
        include = ["**"],
        exclude = ["WORKSPACE", "BUILD", "*.bazel"],
    ),
    visibility = ["//visibility:public"],
)

terraform_toolchain(
    name = "toolchain",
    terraform = ":terraform_bin",
    version = "{version}",
    visibility = ["//visibility:public"],
)

alias(
    name = "{name}",
    actual = ":toolchain",
    visibility = ["//visibility:public"],
)
"""

def terraform_toolchain_repository(*, name, version, platform, url, integrity = "", sha256 = "", binary_name = "terraform"):
    """Download a Terraform-compatible binary and instantiate toolchain targets.

    Args:
        name: (str) The name of the repository to create.
        version: (str) The version string (e.g., `1.14.1` for Terraform,
            `1.10.6` for OpenTofu).
        platform: (str) The target platform (e.g., `linux_amd64`,
            `darwin_arm64`).
        url: (str) URL to fetch the binary archive from.
        integrity: (str) Integrity checksum of the archive, for releases in
            the shipped table.
        sha256: (str) Hex checksum, for releases resolved from a
            `SHA256SUMS` file. Exactly one of `integrity` and `sha256` is set.
        binary_name: (str) File name of the executable inside the archive
            (`terraform` for Terraform, `tofu` for OpenTofu). Windows
            adds `.exe`.

    Returns:
        (str) The provided name.
    """
    bin_file = binary_name + ".exe" if platform.startswith("windows_") else binary_name

    if bool(integrity) == bool(sha256):
        fail("terraform_toolchain_repository {}: exactly one of integrity and sha256 must be set".format(name))
    http_archive(
        name = name,
        urls = [url],
        integrity = integrity,
        sha256 = sha256,
        build_file_content = _TERRAFORM_TOOLCHAIN_BUILD_FILE_CONTENT.format(
            name = name,
            version = version,
            terraform_bin = bin_file,
        ),
    )

    return name

# One per version the hub knows, matching the engine's `version` flag. The
# default version gets a second `toolchain()` matching the flag's empty
# default, since a `toolchain()` cannot say "this setting or that one".
_CONFIG_SETTING_TEMPLATE = """
config_setting(
    name = "{name}",
    flag_values = {{"{flag}": "{value}"}},
    visibility = ["//visibility:public"],
)
"""

_BUILD_FILE_FOR_TOOLCHAIN_HUB_TEMPLATE = """
toolchain(
    name = "{name}",
    exec_compatible_with = {exec_constraint_sets_serialized},
    target_compatible_with = {target_constraint_sets_serialized},
    target_settings = {target_settings_serialized},
    toolchain = "{toolchain}",
    toolchain_type = "{toolchain_type}",
    visibility = ["//visibility:public"],
)
"""

def _BUILD_for_toolchain_hub(
        toolchain_names,
        toolchain_labels,
        target_compatible_with,
        exec_compatible_with,
        target_settings,
        toolchain_type,
        version_flag,
        versions,
        default_version):
    parts = []
    for version in versions:
        parts.append(_CONFIG_SETTING_TEMPLATE.format(
            name = "version_" + version.replace(".", "_"),
            flag = version_flag,
            value = version,
        ))
    if default_version:
        parts.append(_CONFIG_SETTING_TEMPLATE.format(name = "version_default", flag = version_flag, value = ""))

    default_setting = ":version_" + default_version.replace(".", "_") if default_version else None
    for toolchain_name in toolchain_names:
        settings = target_settings.get(toolchain_name, [])
        parts.append(_BUILD_FILE_FOR_TOOLCHAIN_HUB_TEMPLATE.format(
            name = toolchain_name,
            exec_constraint_sets_serialized = json.encode(exec_compatible_with[toolchain_name]),
            target_constraint_sets_serialized = json.encode(target_compatible_with.get(toolchain_name, [])),
            target_settings_serialized = json.encode(settings),
            toolchain = toolchain_labels[toolchain_name],
            toolchain_type = toolchain_type,
        ))
        if default_setting and default_setting in settings:
            parts.append(_BUILD_FILE_FOR_TOOLCHAIN_HUB_TEMPLATE.format(
                name = toolchain_name + "_default",
                exec_constraint_sets_serialized = json.encode(exec_compatible_with[toolchain_name]),
                target_constraint_sets_serialized = json.encode(target_compatible_with.get(toolchain_name, [])),
                target_settings_serialized = json.encode([":version_default"]),
                toolchain = toolchain_labels[toolchain_name],
                toolchain_type = toolchain_type,
            ))
    return "\n".join(parts)

def _terraform_toolchain_repository_hub_impl(repository_ctx):
    repository_ctx.file("WORKSPACE.bazel", """workspace(name = "{}")""".format(
        repository_ctx.name,
    ))

    repository_ctx.file("BUILD.bazel", _BUILD_for_toolchain_hub(
        toolchain_names = repository_ctx.attr.toolchain_names,
        toolchain_labels = repository_ctx.attr.toolchain_labels,
        target_compatible_with = repository_ctx.attr.target_compatible_with,
        exec_compatible_with = repository_ctx.attr.exec_compatible_with,
        target_settings = repository_ctx.attr.target_settings,
        toolchain_type = repository_ctx.attr.toolchain_type,
        version_flag = repository_ctx.attr.version_flag,
        versions = repository_ctx.attr.versions,
        default_version = repository_ctx.attr.default_version,
    ))

terraform_toolchain_repository_hub = repository_rule(
    doc = (
        "Generates a toolchain-bearing repository that declares a set of toolchains from other " +
        "repositories. Used for both Terraform and OpenTofu — the caller picks `toolchain_type`."
    ),
    attrs = {
        "default_version": attr.string(
            doc = "Version whose toolchains also match the flag's empty default.",
        ),
        "exec_compatible_with": attr.string_list_dict(
            mandatory = True,
        ),
        "target_compatible_with": attr.string_list_dict(
            mandatory = True,
        ),
        "target_settings": attr.string_list_dict(
            doc = "config_setting labels attached to each toolchain via `target_settings`.",
        ),
        "toolchain_labels": attr.string_dict(
            mandatory = True,
        ),
        "toolchain_names": attr.string_list(
            mandatory = True,
        ),
        "toolchain_type": attr.string(
            doc = "Fully-qualified label of the toolchain_type to bind to.",
            default = "@rules_terraform//terraform:toolchain_type",
        ),
        "version_flag": attr.string(
            doc = "Label of the `string_flag` the generated `config_setting`s match.",
        ),
        "versions": attr.string_list(
            doc = "Versions to generate a `version_<v>` config_setting for.",
        ),
    },
    implementation = _terraform_toolchain_repository_hub_impl,
)
