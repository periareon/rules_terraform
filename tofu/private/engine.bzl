"""What makes `//tofu` OpenTofu: the one `engine_config` the shared rules read."""

load("//engine:engine.bzl", "engine_config")
load(":versions.bzl", "TOFU_DEFAULT_VERSION", "TOFU_VERSIONS")

visibility(["//tofu/..."])

TOFU_ENGINE = engine_config(
    name = "tofu",
    toolchain_type = str(Label("//tofu:toolchain_type")),
    hub_bzl = str(Label("//tofu/private:hub.bzl")),
    cli_hub = "tofu",
    registry = "registry.opentofu.org",
    # OpenTofu also loads `.tofu` files, which take precedence over a `.tf`
    # of the same name; Terraform ignores them.
    source_extensions = [".tf", ".tf.json", ".tofu", ".tofu.json"],
    versions = TOFU_VERSIONS,
    default_version = TOFU_DEFAULT_VERSION,
    binary_name = "tofu",
    archive_prefix = "tofu",
    sha256sums_url = lambda v: "https://github.com/opentofu/opentofu/releases/download/v{v}/tofu_{v}_SHA256SUMS".format(v = v),
    download_url = lambda v, p: "https://github.com/opentofu/opentofu/releases/download/v{v}/tofu_{v}_{p}.zip".format(v = v, p = p),
    format_ignore_tags = [
        "no_tofu_format",
        "no_tofu_fmt",
        "no_tofufmt",
        "notofufmt",
    ],
    validate_ignore_tags = [
        "no_tofu_validate",
        "no_tofu_validation",
        "no_tofuvalidate",
        "notofuvalidate",
    ],
)
