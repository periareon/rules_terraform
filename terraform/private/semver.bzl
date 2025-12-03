"""Semantic version parsing + constraint checking in Starlark.

Port of `//terraform/private/internal/semver/semver.go`. Same operator set,
same prerelease semantics (SemVer 2.0 §11), same "stable-first, fall back
to prerelease" version selection.

Used by the `terraform.modules(...)` / `opentofu.modules(...)` bzlmod
extensions to resolve a module block's version constraint against the
list the registry returns.
"""

visibility(["//opentofu/...", "//terraform/..."])

_OPS = [">=", "<=", "~>", "!=", ">", "<", "="]

def _cmp_int(a, b):
    if a < b:
        return -1
    if a > b:
        return 1
    return 0

def _parse_int(s):
    """Return (int, True) if s is a non-negative integer, else (0, False)."""
    if not s:
        return 0, False
    for ch in s.elems():
        if ch < "0" or ch > "9":
            return 0, False
    return int(s), True

def _compare_ident(a, b):
    an, aok = _parse_int(a)
    bn, bok = _parse_int(b)
    if aok and bok:
        return _cmp_int(an, bn)
    if aok:
        return -1
    if bok:
        return 1
    if a < b:
        return -1
    if a > b:
        return 1
    return 0

def _compare_pre(a, b):
    if a == b:
        return 0
    if a == "":
        return 1
    if b == "":
        return -1
    af = a.split(".")
    bf = b.split(".")
    limit = min(len(af), len(bf))
    for i in range(limit):
        c = _compare_ident(af[i], bf[i])
        if c != 0:
            return c
    return _cmp_int(len(af), len(bf))

def parse_version(s):
    """Parse `major[.minor[.patch]][-prerelease][+build]` into a struct.

    Args:
        s: (str) The version string. Accepts an optional leading `v`.

    Returns:
        (struct|None) `struct(major, minor, patch, prerelease, original)` on
        success; None on parse failure.
    """
    original = s
    if s.startswith("v"):
        s = s[1:]

    plus = s.find("+")
    if plus >= 0:
        s = s[:plus]

    pre = ""
    dash = s.find("-")
    if dash >= 0:
        pre = s[dash + 1:]
        s = s[:dash]

    parts = s.split(".")
    if len(parts) < 1 or len(parts) > 3:
        return None

    nums = [0, 0, 0]
    for i in range(len(parts)):
        n, ok = _parse_int(parts[i])
        if not ok:
            return None
        nums[i] = n

    return struct(
        major = nums[0],
        minor = nums[1],
        patch = nums[2],
        prerelease = pre,
        original = original,
    )

def compare_versions(a, b):
    """Return -1 / 0 / 1 comparing two `parse_version` results.

    Args:
        a: (struct) First parsed version.
        b: (struct) Second parsed version.

    Returns:
        (int) -1 if a<b, 0 if a==b, 1 if a>b.
    """
    c = _cmp_int(a.major, b.major)
    if c != 0:
        return c
    c = _cmp_int(a.minor, b.minor)
    if c != 0:
        return c
    c = _cmp_int(a.patch, b.patch)
    if c != 0:
        return c
    return _compare_pre(a.prerelease, b.prerelease)

def _parse_one_constraint(raw):
    for op in _OPS:
        if raw.startswith(op):
            v = parse_version(raw[len(op):].strip())
            if v == None:
                return None
            return struct(op = op, version = v)
    v = parse_version(raw)
    if v == None:
        return None
    return struct(op = "=", version = v)

def parse_constraints(s):
    """Parse a comma-separated constraint list.

    Args:
        s: (str) Constraint string like `">= 1.0, < 2.0"` or `"~> 5.0"`.
            An empty string returns an empty list (matches any version).

    Returns:
        (list[struct]|None) List of `struct(op, version)`. None on parse
        failure.
    """
    s = s.strip()
    if not s:
        return []
    out = []
    for raw in s.split(","):
        raw = raw.strip()
        if not raw:
            continue
        c = _parse_one_constraint(raw)
        if c == None:
            return None
        out.append(c)
    return out

def _check_one(constraint, v):
    cmp = compare_versions(v, constraint.version)
    op = constraint.op
    if op == "=":
        return cmp == 0
    if op == "!=":
        return cmp != 0
    if op == ">":
        return cmp > 0
    if op == ">=":
        return cmp >= 0
    if op == "<":
        return cmp < 0
    if op == "<=":
        return cmp <= 0
    if op == "~>":
        # Pessimistic operator: allow patch-level bumps when 3 segments were
        # given, minor-level when 2 were given.
        if cmp < 0:
            return False
        base = constraint.version.original
        if base.startswith("v"):
            base = base[1:]
        base_no_pre = base.split("-")[0]
        segments = 1 + base_no_pre.count(".")
        if segments == 1:
            return True
        if segments == 2:
            return v.major == constraint.version.major
        return v.major == constraint.version.major and v.minor == constraint.version.minor
    return False

def check(constraints, v):
    """Return True iff `v` satisfies every entry in `constraints`.

    Args:
        constraints: (list[struct]) Result of `parse_constraints`.
        v: (struct) Parsed version.

    Returns:
        (bool)
    """
    for c in constraints:
        if not _check_one(c, v):
            return False
    return True

def highest_matching(versions, constraints):
    """Pick the highest version that satisfies every constraint.

    Prefers stable releases; falls back to prereleases only when no stable
    version qualifies. Returns None if no version satisfies the constraint.

    Args:
        versions: (list[struct]) Parsed versions to choose from.
        constraints: (list[struct]) Constraint list; empty matches anything.

    Returns:
        (struct|None) The selected version, or None.
    """
    best_stable = None
    best_pre = None
    for v in versions:
        if constraints and not check(constraints, v):
            continue
        if v.prerelease:
            if best_pre == None or compare_versions(v, best_pre) > 0:
                best_pre = v
        elif best_stable == None or compare_versions(v, best_stable) > 0:
            best_stable = v
    if best_stable != None:
        return best_stable
    return best_pre
