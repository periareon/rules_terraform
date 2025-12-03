"""Public build settings for `//opentofu`.

Each exported function is named after a build setting in this package and
its docstring describes what the setting does. The function body returns
the setting's label so callers can reference it programmatically.
"""

load(
    "//opentofu/private:versions.bzl",
    "TOFU_DEFAULT_VERSION",
    "TOFU_VERSIONS",
)

visibility(["//opentofu/..."])

TOFU_VERSION_LIST = sorted(TOFU_VERSIONS.keys())

# Baked default (latest version — computed by the update_versions tool from
# the full versions table and written into `versions.bzl`).
TOFU_DEFAULT_VERSION_VALUE = TOFU_DEFAULT_VERSION

def version():
    """Picks which OpenTofu release the auto-registered toolchains resolve to.

    rules_terraform ships one toolchain per (version, platform) combination
    in `TOFU_VERSIONS`, each guarded by a `config_setting` that matches
    this flag; Bazel's toolchain resolver picks the matching one. The
    corresponding `http_archive` is fetched lazily on first use.

    Flip the flag globally in `.bazelrc`, per-invocation via
    `--@rules_terraform//opentofu/settings:version=1.10.6`, or per-target
    with a Starlark configuration transition.

    Defaults to the latest stable release listed in
    `//opentofu/private:versions.bzl` (`TOFU_DEFAULT_VERSION`), computed
    by `tools/update_versions` from the shipped versions table.

    Returns:
        (str) The fully-qualified label of the string flag.
    """
    return "@rules_terraform//opentofu/settings:version"
