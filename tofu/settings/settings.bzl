"""Public build settings for `//tofu`.

Each exported function is named after a build setting in this package and
its docstring describes what the setting does. The function body returns
the setting's label so callers can reference it programmatically.
"""

visibility(["//tofu/..."])

def version():
    """Picks which OpenTofu release the auto-registered toolchains resolve to.

    The `tofu_toolchains` extension declares one toolchain per (version, platform)
    for the releases shipped in `//tofu/private:versions.bzl` — the
    newest three when the table was generated — and for any release a
    `tofu_toolchains.version(version = "…")` tag asks for. For a tagged release the
    extension fetches the release's `SHA256SUMS` once and records the
    checksums as facts in `MODULE.bazel.lock`, so an older pin costs no
    change to rules_terraform and no network on later evaluations.

    Empty, the default, selects the extension's default: the release the
    root module marked `version(…, default = True)`, else the newest
    shipped one. Any other value names one of the known releases. Set it
    globally in `.bazelrc`, per invocation via
    `--@rules_terraform//tofu/settings:version=1.9.1`, or per target
    with a Starlark configuration transition. The corresponding archive is
    fetched lazily on first use.

    Returns:
        (str) The fully-qualified label of the string flag.
    """
    return "@rules_terraform//tofu/settings:version"
