"""Utlities for parsing `.terraform_lock.hcl` files"""

visibility(["//opentofu/...", "//terraform/...", "//tests/..."])

def _tf_provider(*, source, version, constraints, hashes):
    """A starlark representation of a Terraform provider lock entry.

    Args:
        source: (str) The provider source.
        version: (str) The version of the provider.
        constraints: (str) The constraint used to match the provider.
        hashes: (list[str]) A list of hashes.

    Returns:
        (struct) The struct based on the args.
    """
    return struct(
        source = source,
        version = version,
        constraints = constraints,
        hashes = hashes,
    )

def parse_lock_file(lock_content):
    """Parse a .terraform.lock.hcl file and extract provider information.

    Args:
        lock_content: (str) String content of the lock file

    Returns:
        (list[struct]) List of `tf_provider` structs.
    """
    providers = []
    lines = lock_content.split("\n")

    # Track state while parsing
    in_provider = False
    in_hashes = False
    current_provider = None

    for line in lines:
        stripped = line.strip()

        # Look for provider block start
        if stripped.startswith("provider "):
            # Extract provider source from the quoted string
            # Format: provider "registry.terraform.io/namespace/name" {
            parts = stripped.split('"')
            if len(parts) >= 2:
                source = parts[1]

                # Strip the default registry hostname prefix (either engine's)
                # so `provider.source` is always the canonical `namespace/name`
                # form the download-URL template expects.
                for host_prefix in ("registry.terraform.io/", "registry.opentofu.org/"):
                    if source.startswith(host_prefix):
                        source = source[len(host_prefix):]
                        break

                current_provider = {
                    "constraints": "",
                    "hashes": [],
                    "source": source,
                    "version": "",
                }
                in_provider = True
                in_hashes = False

        elif in_provider:
            # Check for end of provider block
            if stripped == "}":
                if current_provider:
                    providers.append(_tf_provider(**current_provider))
                    current_provider = None
                in_provider = False
                in_hashes = False

                # Check for end of hashes array
            elif in_hashes and stripped == "]":
                in_hashes = False

                # Parse values inside hashes array
            elif in_hashes:
                # Remove quotes and commas
                hash_value = stripped.strip('",')
                if hash_value and not hash_value.startswith("#") and current_provider:
                    current_provider["hashes"].append(hash_value)

                # Parse version
            elif stripped.startswith("version"):
                # Format: version = "3.2.4" or version     = "3.2.4"
                value_parts = stripped.split("=", 1)
                if len(value_parts) == 2 and current_provider:
                    version_str = value_parts[1].strip()

                    # Remove quotes
                    current_provider["version"] = version_str.strip('"')

                # Parse constraints
            elif stripped.startswith("constraints"):
                value_parts = stripped.split("=", 1)
                if len(value_parts) == 2 and current_provider:
                    constraints_str = value_parts[1].strip()
                    current_provider["constraints"] = constraints_str.strip('"')

                # Start of hashes array
            elif stripped.startswith("hashes"):
                in_hashes = True

    return providers
