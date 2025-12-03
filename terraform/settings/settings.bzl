"""Public build settings for `//terraform`.

Each exported function is named after a build setting in this package and
its docstring describes what the setting does. The function body returns
the setting's label so callers can reference it programmatically.
"""

load(
    "//terraform/private:versions.bzl",
    "TERRAFORM_DEFAULT_VERSION",
    "TERRAFORM_VERSIONS",
)

visibility(["//terraform/..."])

# Sorted list of known Terraform versions, consumed by the sibling
# `BUILD.bazel` to generate one `config_setting` per version.
TERRAFORM_VERSION_LIST = sorted(TERRAFORM_VERSIONS.keys())

# Baked default (latest version — computed by the update_versions tool from
# the full versions table and written into `versions.bzl`).
TERRAFORM_DEFAULT_VERSION_VALUE = TERRAFORM_DEFAULT_VERSION

def version():
    """Picks which Terraform release the auto-registered toolchains resolve to.

    rules_terraform ships one toolchain per (version, platform) combination
    in `TERRAFORM_VERSIONS`, each guarded by a `config_setting` that
    matches this flag; Bazel's toolchain resolver picks the matching one.
    The corresponding `http_archive` is fetched lazily on first use, so
    declaring dozens of versions does not slow down builds that only use
    one.

    Flip the flag globally in `.bazelrc`, per-invocation via
    `--@rules_terraform//terraform/settings:version=1.10.5`, or per-target
    with a Starlark configuration transition.

    Defaults to the latest stable release listed in
    `//terraform/private:versions.bzl` (`TERRAFORM_DEFAULT_VERSION`),
    computed by `tools/update_versions` from the shipped versions table.

    Returns:
        (str) The fully-qualified label of the string flag.
    """
    return "@rules_terraform//terraform/settings:version"
