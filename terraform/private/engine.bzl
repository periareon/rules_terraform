"""What makes `//terraform` Terraform: the one `engine_config` the shared rules read."""

load("//engine:engine.bzl", "engine_config")
load(":versions.bzl", "TERRAFORM_DEFAULT_VERSION", "TERRAFORM_VERSIONS")

visibility(["//terraform/..."])

TERRAFORM_ENGINE = engine_config(
    name = "terraform",
    toolchain_type = str(Label("//terraform:toolchain_type")),
    hub_bzl = str(Label("//terraform/private:hub.bzl")),
    cli_hub = "terraform",
    registry = "registry.terraform.io",
    source_extensions = [".tf", ".tf.json"],
    versions = TERRAFORM_VERSIONS,
    default_version = TERRAFORM_DEFAULT_VERSION,
    binary_name = "terraform",
    archive_prefix = "terraform",
    sha256sums_url = lambda v: "https://releases.hashicorp.com/terraform/{v}/terraform_{v}_SHA256SUMS".format(v = v),
    download_url = lambda v, p: "https://releases.hashicorp.com/terraform/{v}/terraform_{v}_{p}.zip".format(v = v, p = p),
    format_ignore_tags = [
        "no_terraform_format",
        "no_terraform_fmt",
        "no_terraformfmt",
        "noterraformfmt",
    ],
    validate_ignore_tags = [
        "no_terraform_validate",
        "no_terraform_validation",
        "no_terraformvalidate",
        "noterraformvalidate",
    ],
)
