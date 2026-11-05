"""Repositories holding one engine release each, and the hub that registers them.

Engine-agnostic: the binary name, the toolchain type and the `.bzl` file the
generated BUILD files load come from the caller.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

visibility(["//engine/...", "//terraform/...", "//tofu/..."])

_TERRAFORM_TOOLCHAIN_BUILD_FILE_CONTENT = """\
load("{hub_bzl}", "terraform_toolchain")

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

def terraform_toolchain_repository(*, name, version, platform, url, integrity, sha256, binary_name, hub_bzl):
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
        hub_bzl: (str) Label of the `.bzl` file the generated BUILD file
            loads `terraform_toolchain` from.

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
            hub_bzl = hub_bzl,
        ),
    )

    return name

_BUILD_FILE_FOR_TOOLCHAIN_HUB_TEMPLATE = """
toolchain(
    name = "{name}",
    exec_compatible_with = {exec_constraint_sets_serialized},
    target_compatible_with = {target_constraint_sets_serialized},
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
        toolchain_type):
    return "\n".join([
        _BUILD_FILE_FOR_TOOLCHAIN_HUB_TEMPLATE.format(
            name = toolchain_name,
            exec_constraint_sets_serialized = json.encode(exec_compatible_with[toolchain_name]),
            target_constraint_sets_serialized = json.encode(target_compatible_with.get(toolchain_name, [])),
            toolchain = toolchain_labels[toolchain_name],
            toolchain_type = toolchain_type,
        )
        for toolchain_name in toolchain_names
    ])

def _terraform_toolchain_repository_hub_impl(repository_ctx):
    repository_ctx.file("WORKSPACE.bazel", """workspace(name = "{}")""".format(
        repository_ctx.name,
    ))

    repository_ctx.file("BUILD.bazel", _BUILD_for_toolchain_hub(
        toolchain_names = repository_ctx.attr.toolchain_names,
        toolchain_labels = repository_ctx.attr.toolchain_labels,
        target_compatible_with = repository_ctx.attr.target_compatible_with,
        exec_compatible_with = repository_ctx.attr.exec_compatible_with,
        toolchain_type = repository_ctx.attr.toolchain_type,
    ))

terraform_toolchain_repository_hub = repository_rule(
    doc = (
        "Generates a toolchain-bearing repository that declares a set of toolchains from other " +
        "repositories, one release across every platform. Used for both Terraform and " +
        "OpenTofu — the caller picks `toolchain_type`."
    ),
    attrs = {
        "exec_compatible_with": attr.string_list_dict(
            mandatory = True,
        ),
        "target_compatible_with": attr.string_list_dict(
            mandatory = True,
        ),
        "toolchain_labels": attr.string_dict(
            mandatory = True,
        ),
        "toolchain_names": attr.string_list(
            mandatory = True,
        ),
        "toolchain_type": attr.string(
            doc = "Fully-qualified label of the toolchain_type to bind to.",
            mandatory = True,
        ),
    },
    implementation = _terraform_toolchain_repository_hub_impl,
)
