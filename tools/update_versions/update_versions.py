"""Render `TERRAFORM_VERSIONS` / `TOFU_VERSIONS` .bzl files from upstream release metadata.

The two engines differ in how they publish releases and checksums:

* Terraform: HTML listing at `releases.hashicorp.com` + SHA256SUMS files there.
* OpenTofu: GitHub Releases API + SHA256SUMS assets attached to each release.

Everything downstream (checksum parsing, integrity conversion, output template)
is shared, so both engines flow through the same pipeline once versions have
been discovered.
"""

import argparse
import base64
import binascii
import json
import logging
import os
import re
import urllib.request
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from typing import Callable

_TERRAFORM_TEMPLATE = """\
\"\"\"Terraform Versions

AUTO-GENERATED: DO NOT MODIFY

Update using the following command:

```bash
bazel run //tools/update_versions -- --engine=terraform
```
\"\"\"

TERRAFORM_VERSIONS = {versions}

TERRAFORM_DEFAULT_VERSION = "{default}"
"""

_TOFU_TEMPLATE = """\
\"\"\"OpenTofu Versions

AUTO-GENERATED: DO NOT MODIFY

Update using the following command:

```bash
bazel run //tools/update_versions -- --engine=opentofu
```
\"\"\"

TOFU_VERSIONS = {versions}

TOFU_DEFAULT_VERSION = "{default}"
"""


@dataclass
class EngineConfig:
    name: str
    list_versions: Callable[[], list[str]]
    sha256sums_url: Callable[[str], str]
    download_url: Callable[[str, str], str]
    # Regex over lines in SHA256SUMS that captures (hex, platform).
    # Groups: 1=hex, 2=platform (e.g. "linux_amd64").
    checksum_line: re.Pattern
    output_path: Path
    template: str
    versions_var: str
    default_var: str


def _integrity(hex_str: str) -> str:
    """Convert a sha256 hex value to a Bazel integrity value."""
    try:
        raw_bytes = binascii.unhexlify(hex_str.strip())
    except binascii.Error as e:
        raise ValueError(f"Invalid hex input: {e}") from e
    return f"sha256-{base64.b64encode(raw_bytes).decode('utf-8')}"


def _fetch_url(url: str) -> str:
    logging.debug(f"GET {url}")
    with urllib.request.urlopen(url) as resp:
        return resp.read().decode("utf-8")


def _fetch_terraform_releases() -> list[str]:
    """Scrape `releases.hashicorp.com/terraform/` for version tags."""

    class ReleasesParser(HTMLParser):
        def __init__(self):
            super().__init__()
            self.versions: list[str] = []

        def handle_starttag(self, tag, attrs):
            if tag != "a":
                return
            for attr, value in attrs:
                if attr == "href" and value.startswith("/terraform/"):
                    _, _, version = value.strip("/").partition("/")
                    if version:
                        self.versions.append(version)

    html = _fetch_url("https://releases.hashicorp.com/terraform/")
    parser = ReleasesParser()
    parser.feed(html)
    return parser.versions


def _fetch_opentofu_releases() -> list[str]:
    """Walk the OpenTofu GitHub Releases API. Handles pagination."""
    versions: list[str] = []
    url = "https://api.github.com/repos/opentofu/opentofu/releases?per_page=100"
    while url:
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
            link_header = resp.headers.get("Link", "")
        for release in payload:
            tag = release.get("tag_name", "")
            if release.get("draft") or release.get("prerelease"):
                continue
            if tag.startswith("v"):
                tag = tag[1:]
            if tag:
                versions.append(tag)

        url = _next_link(link_header)
    return versions


def _next_link(link_header: str) -> str | None:
    for part in link_header.split(","):
        segment = part.strip()
        if segment.endswith('rel="next"'):
            start = segment.find("<")
            end = segment.find(">")
            if start != -1 and end > start:
                return segment[start + 1 : end]
    return None


def _is_stable(version: str) -> bool:
    return not any(m in version.lower() for m in ("alpha", "beta", "rc", "dev"))


def _parse_version(version_str: str) -> tuple[int, ...]:
    stripped = version_str.lstrip("v").split("-")[0]
    try:
        return tuple(int(x) for x in stripped.split("."))
    except ValueError:
        logging.warning(f"Could not parse version: {version_str}")
        return (0, 0, 0)


def _fetch_checksums(config: EngineConfig, version: str) -> dict[str, str]:
    """Parse a SHA256SUMS payload into {platform: hex}."""
    try:
        content = _fetch_url(config.sha256sums_url(version))
    except Exception as e:
        logging.warning(f"failed to fetch SHA256SUMS for {config.name} {version}: {e}")
        return {}

    checksums: dict[str, str] = {}
    for line in content.strip().splitlines():
        m = config.checksum_line.match(line.strip())
        if not m:
            continue
        checksums[m.group("platform")] = m.group("hex")
    return checksums


def _build_versions(config: EngineConfig, version: str, checksums: dict[str, str]) -> dict[str, dict[str, str]]:
    out: dict[str, dict[str, str]] = {}
    for platform, hex_hash in checksums.items():
        try:
            out[platform] = {
                "url": config.download_url(version, platform),
                "integrity": _integrity(hex_hash),
            }
        except ValueError as e:
            logging.warning(f"skip {config.name} {version}/{platform}: {e}")
    return out


_TERRAFORM_CHECKSUM_LINE = re.compile(
    # "<sha256>  terraform_<version>_<platform>.zip"
    r"^(?P<hex>[0-9a-f]{64})\s+terraform_[^_]+_(?P<platform>[a-z0-9]+_[a-z0-9]+)\.zip$",
    re.IGNORECASE,
)

_TOFU_CHECKSUM_LINE = re.compile(
    # "<sha256>  tofu_<version>_<os>_<arch>.zip" — exclude .rpm/.deb/.apk/.tar.gz/etc.
    r"^(?P<hex>[0-9a-f]{64})\s+tofu_[^_]+_(?P<platform>[a-z0-9]+_[a-z0-9]+)\.zip$",
    re.IGNORECASE,
)


def _terraform_config(repo_root: Path) -> EngineConfig:
    return EngineConfig(
        name="terraform",
        list_versions=_fetch_terraform_releases,
        sha256sums_url=lambda v: f"https://releases.hashicorp.com/terraform/{v}/terraform_{v}_SHA256SUMS",
        download_url=lambda v, p: f"https://releases.hashicorp.com/terraform/{v}/terraform_{v}_{p}.zip",
        checksum_line=_TERRAFORM_CHECKSUM_LINE,
        output_path=repo_root / "terraform/private/versions.bzl",
        template=_TERRAFORM_TEMPLATE,
        versions_var="TERRAFORM_VERSIONS",
        default_var="TERRAFORM_DEFAULT_VERSION",
    )


def _opentofu_config(repo_root: Path) -> EngineConfig:
    return EngineConfig(
        name="opentofu",
        list_versions=_fetch_opentofu_releases,
        sha256sums_url=lambda v: f"https://github.com/opentofu/opentofu/releases/download/v{v}/tofu_{v}_SHA256SUMS",
        download_url=lambda v, p: f"https://github.com/opentofu/opentofu/releases/download/v{v}/tofu_{v}_{p}.zip",
        checksum_line=_TOFU_CHECKSUM_LINE,
        output_path=repo_root / "opentofu/private/versions.bzl",
        template=_TOFU_TEMPLATE,
        versions_var="TOFU_VERSIONS",
        default_var="TOFU_DEFAULT_VERSION",
    )


def parse_args() -> argparse.Namespace:
    repo_root = Path(__file__).parent.parent.parent
    if "BUILD_WORKSPACE_DIRECTORY" in os.environ:
        repo_root = Path(os.environ["BUILD_WORKSPACE_DIRECTORY"])

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--engine",
        choices=("terraform", "opentofu", "all"),
        default="all",
        help="Which engine's versions to render. `all` renders both.",
    )
    parser.add_argument(
        "--min-version",
        default="1.0.0",
        help="Minimum version to include (semver-comparable).",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Override the output path (only valid with a single --engine).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
    )
    parser.set_defaults(repo_root=repo_root)
    return parser.parse_args()


def render(config: EngineConfig, min_version: str, output_override: Path | None) -> None:
    logging.info(f"[{config.name}] listing releases")
    all_versions = config.list_versions()
    logging.info(f"[{config.name}] {len(all_versions)} total releases")

    stable = [v for v in all_versions if _is_stable(v)]
    logging.info(f"[{config.name}] {len(stable)} stable releases")

    min_tuple = _parse_version(min_version)
    kept = [v for v in stable if _parse_version(v) >= min_tuple]
    kept.sort(key=_parse_version, reverse=True)
    logging.info(f"[{config.name}] {len(kept)} releases >= {min_version}")

    versions: dict[str, dict[str, dict[str, str]]] = {}
    for version in kept:
        logging.info(f"[{config.name}] processing {version}")
        checksums = _fetch_checksums(config, version)
        if not checksums:
            logging.warning(f"[{config.name}] no checksums for {version}, skipping")
            continue
        platforms = _build_versions(config, version, checksums)
        if platforms:
            versions[version] = platforms

    if not versions:
        raise RuntimeError(f"[{config.name}] no versions rendered — aborting rather than overwrite output")

    default_version = max(versions.keys(), key=_parse_version)

    output = output_override or config.output_path
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        config.template.format(
            versions=json.dumps(versions, indent=4, sort_keys=True),
            default=default_version,
        ),
        encoding="utf-8",
    )
    logging.info(f"[{config.name}] wrote {output}")


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)

    engines: list[EngineConfig] = []
    if args.engine in ("terraform", "all"):
        engines.append(_terraform_config(args.repo_root))
    if args.engine in ("opentofu", "all"):
        engines.append(_opentofu_config(args.repo_root))

    if args.output and len(engines) != 1:
        raise SystemExit("--output requires a single --engine")

    for config in engines:
        render(config, args.min_version, args.output)


if __name__ == "__main__":
    main()
