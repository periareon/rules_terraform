"""The platforms an engine or provider binary is published for.

Kept in a file of its own, with no repository-rule loads, because it is
needed on both sides of the fence: repository rules (`toolchain_repo.bzl`,
`provider_repo.bzl`) key fetched archives by it, and the `terraform_provider`
rule detects the platform it is being built for from the same table.
"""

visibility(["//terraform/...", "//tests/...", "//tofu/..."])

PLATFORM_TO_CONSTRAINTS = {
    "darwin_amd64": ["@platforms//os:macos", "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:macos", "@platforms//cpu:aarch64"],
    "freebsd_386": ["@platforms//os:freebsd", "@platforms//cpu:i386"],
    "freebsd_amd64": ["@platforms//os:freebsd", "@platforms//cpu:x86_64"],
    "freebsd_arm": ["@platforms//os:freebsd", "@platforms//cpu:arm"],
    "linux_386": ["@platforms//os:linux", "@platforms//cpu:i386"],
    "linux_amd64": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm": ["@platforms//os:linux", "@platforms//cpu:arm"],
    "linux_arm64": ["@platforms//os:linux", "@platforms//cpu:aarch64"],
    "openbsd_386": ["@platforms//os:openbsd", "@platforms//cpu:i386"],
    "openbsd_amd64": ["@platforms//os:openbsd", "@platforms//cpu:x86_64"],
    "windows_386": ["@platforms//os:windows", "@platforms//cpu:i386"],
    "windows_amd64": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
}

def _all_constraint_labels():
    seen = {}
    for labels in PLATFORM_TO_CONSTRAINTS.values():
        for label in labels:
            seen[label] = True
    return sorted(seen.keys())

# Every constraint_value the table mentions, for rules that detect the target
# platform via `ctx.target_platform_has_constraint`.
PLATFORM_CONSTRAINT_LABELS = _all_constraint_labels()

def detect_platform(ctx, constraint_targets):
    """Name the platform the target configuration is for.

    Args:
        ctx: (ctx) A rule context.
        constraint_targets: (list[Target]) The resolved
            `PLATFORM_CONSTRAINT_LABELS`, from a private label_list attr.

    Returns:
        (str) A key of `PLATFORM_TO_CONSTRAINTS`, e.g. `linux_amd64`.
        Fails when the target platform matches none of them.
    """

    # A label_list attr resolves in declaration order, so pairing by position
    # with the default list is exact. Pairing by label string is not: the
    # canonical repository name a `Label()` renders with is not always the one
    # a resolved target's label renders with.
    if len(constraint_targets) != len(PLATFORM_CONSTRAINT_LABELS):
        fail("{}: expected {} constraint targets, got {}".format(
            ctx.label,
            len(PLATFORM_CONSTRAINT_LABELS),
            len(constraint_targets),
        ))
    by_label = {}
    for i in range(len(PLATFORM_CONSTRAINT_LABELS)):
        by_label[PLATFORM_CONSTRAINT_LABELS[i]] = constraint_targets[i][platform_common.ConstraintValueInfo]

    for platform, labels in PLATFORM_TO_CONSTRAINTS.items():
        matched = True
        for label in labels:
            if not ctx.target_platform_has_constraint(by_label[label]):
                matched = False
                break
        if matched:
            return platform
    fail("{}: the target platform matches none of the engine's supported platforms ({})".format(
        ctx.label,
        ", ".join(PLATFORM_TO_CONSTRAINTS.keys()),
    ))
