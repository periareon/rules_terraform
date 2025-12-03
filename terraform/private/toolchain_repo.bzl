"""Terraform toolchain repository configuration.

Also used by `//opentofu` to fetch the `tofu` binary — the helpers here are
engine-agnostic (binary_name and toolchain_type are both parameters).
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(
    "//terraform/private:versions.bzl",
    _TERRAFORM_DEFAULT_VERSION = "TERRAFORM_DEFAULT_VERSION",
    _TERRAFORM_VERSIONS = "TERRAFORM_VERSIONS",
)

visibility(["//opentofu/...", "//terraform/...", "//tests/..."])

PLATFORM_TO_CONSTRAINTS = {
    "darwin_amd64": ["@platforms//os:macos", "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:macos", "@platforms//cpu:aarch64"],
    "freebsd_386": ["@platforms//os:freebsd", "@platforms//cpu:i386"],
    "freebsd_amd64": ["@platforms//os:freebsd", "@platforms//cpu:x86_64"],
    "freebsd_arm": ["@platforms//os:freebsd", "@platforms//cpu:arm"],
    "linux_386": ["@platforms//os:linux", "@platforms//cpu:i386"],
    "linux_amd64": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm": ["@platforms//os:linux", "@platforms//cpu:arm"],
    "linux_arm64": ["@platforms//os:linux", "@platforms//cpu:aarch64"],
    "openbsd_386": ["@platforms//os:openbsd", "@platforms//cpu:i386"],
    "openbsd_amd64": ["@platforms//os:openbsd", "@platforms//cpu:x86_64"],
    "windows_386": ["@platforms//os:windows", "@platforms//cpu:i386"],
    "windows_amd64": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
}

TERRAFORM_DEFAULT_VERSION = _TERRAFORM_DEFAULT_VERSION

TERRAFORM_VERSIONS = _TERRAFORM_VERSIONS

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

def terraform_toolchain_repository(*, name, version, platform, url, integrity, binary_name = "terraform"):
    """Download a Terraform-compatible binary and instantiate toolchain targets.

    Args:
        name: (str) The name of the repository to create.
        version: (str) The version string (e.g., `1.14.1` for Terraform,
            `1.10.6` for OpenTofu).
        platform: (str) The target platform (e.g., `linux_amd64`,
            `darwin_arm64`).
        url: (str) URL to fetch the binary archive from.
        integrity: (str) Integrity checksum of the archive.
        binary_name: (str) File name of the executable inside the archive
            (`terraform` for Terraform, `tofu` for OpenTofu). Windows
            adds `.exe`.

    Returns:
        (str) The provided name.
    """
    bin_file = binary_name + ".exe" if platform.startswith("windows_") else binary_name

    http_archive(
        name = name,
        urls = [url],
        integrity = integrity,
        build_file_content = _TERRAFORM_TOOLCHAIN_BUILD_FILE_CONTENT.format(
            name = name,
            version = version,
            terraform_bin = bin_file,
        ),
    )

    return name

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
        toolchain_type):
    return "\n".join([_BUILD_FILE_FOR_TOOLCHAIN_HUB_TEMPLATE.format(
        name = toolchain_name,
        exec_constraint_sets_serialized = json.encode(exec_compatible_with[toolchain_name]),
        target_constraint_sets_serialized = json.encode(target_compatible_with.get(toolchain_name, [])),
        target_settings_serialized = json.encode(target_settings.get(toolchain_name, [])),
        toolchain = toolchain_labels[toolchain_name],
        toolchain_type = toolchain_type,
    ) for toolchain_name in toolchain_names])

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
    ))

terraform_toolchain_repository_hub = repository_rule(
    doc = (
        "Generates a toolchain-bearing repository that declares a set of toolchains from other " +
        "repositories. Used for both Terraform and OpenTofu — the caller picks `toolchain_type`."
    ),
    attrs = {
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
    },
    implementation = _terraform_toolchain_repository_hub_impl,
)
