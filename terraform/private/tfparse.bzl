"""Line-oriented `.tf` module-block scanner in Starlark.

Port of the `module { }` extractor in
`//terraform/private/internal/tfparse/tfparse.go`. Same semantics: brace
counting per line, no HCL parser dependency, no string/comment escape
awareness (matches the Go version's limits).

Used by the `terraform.modules(...)` / `opentofu.modules(...)` bzlmod
extensions to enumerate module block references without shelling out.
"""

visibility(["//opentofu/...", "//terraform/..."])

def _matches_module_header(stripped):
    """Return the module-block key if `stripped` opens a `module "…" {` block."""
    if not stripped.startswith("module"):
        return None

    # After `module`, expect whitespace, then `"key"`, then whitespace, then `{`.
    rest = stripped[len("module"):]
    if not rest or (rest[0] != " " and rest[0] != "\t"):
        return None
    rest = rest.lstrip()
    if not rest.startswith("\""):
        return None
    end = rest.find("\"", 1)
    if end < 0:
        return None
    key = rest[1:end]
    tail = rest[end + 1:].lstrip()
    if not tail.startswith("{"):
        return None
    return key

def _attr_value(stripped, name):
    """Return the string value of `<name> = "…"` on this line, or `None`."""
    if not stripped.startswith(name):
        return None
    rest = stripped[len(name):]
    if not rest or (rest[0] != " " and rest[0] != "\t" and rest[0] != "="):
        return None
    rest = rest.lstrip()
    if not rest.startswith("="):
        return None
    rest = rest[1:].lstrip()
    if not rest.startswith("\""):
        return None
    end = rest.find("\"", 1)
    if end < 0:
        return None
    return rest[1:end]

def parse_module_blocks(content):
    """Extract every `module "…" { … }` block declared in `content`.

    Args:
        content: (str) Concatenated text of one or more `.tf` files.

    Returns:
        (list[struct]) List of `struct(key, source, version)`. `source`
        and `version` are empty strings if the block didn't set them.
    """
    out = []
    current = None
    depth = 0

    for line in content.split("\n"):
        stripped = line.lstrip()

        if current == None:
            key = _matches_module_header(stripped)
            if key != None:
                current = {"key": key, "source": "", "version": ""}
                depth = 1
            continue

        if depth == 1:
            src = _attr_value(stripped, "source")
            if src != None:
                current["source"] = src
            else:
                ver = _attr_value(stripped, "version")
                if ver != None:
                    current["version"] = ver

        depth += line.count("{") - line.count("}")
        if depth <= 0:
            out.append(struct(
                key = current["key"],
                source = current["source"],
                version = current["version"],
            ))
            current = None
            depth = 0

    return out
