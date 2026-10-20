"""The body of the `terraform` and `tofu` module extensions.

Both carry one tag class, `deps`, and differ only in which registry a tag
that names none is resolved against: `registry.terraform.io` for
`terraform`, `registry.opentofu.org` for `tofu`. Everything else — reading
lock files, pooling archives, resolving registry modules, recording facts —
is this file.

A `deps` tag describes what a root module needs from outside the workspace,
the way `terraform init` sees it: the providers its lock file pins and the
registry modules its `module` blocks name. Both halves are optional; the hub
carries whichever were given.

An OpenTofu-only repository uses the `tofu` extension for everything and
never loads `//terraform:extensions.bzl`. A repository using both engines on
the same dependencies should pick one extension for them: each extension
pools its own archives, so the same provider declared through both is
fetched twice.
"""

load(":deps_hub.bzl", "terraform_deps_hub")
load(":modules_extension.bzl", "claim_hub_name", "declare_module_pool", "resolve_registry_modules")
load(":provider_repo.bzl", "declare_provider_pool", "resolve_providers_from_lock_file")

visibility(["//terraform/...", "//tofu/..."])

def run_extension(module_ctx, *, registry_default):
    """Evaluate every `deps` tag and declare its repositories.

    Args:
        module_ctx: (module_ctx) The extension context.
        registry_default: (str) Registry queried when a tag leaves
            `registry` empty: for lock entries that name a public
            registry, and for `module` blocks whose source names no host.

    Returns:
        (extension_metadata) `reproducible = False`, carrying this
        evaluation's facts: provider lookups and module archives both.
    """
    supports_facts = hasattr(module_ctx, "facts")
    existing_facts = module_ctx.facts if supports_facts else None
    new_facts = {}

    # Every hub is resolved before anything is declared: the pools are
    # shared, and a hub cannot know what another will add to them. Hub names
    # share one namespace across every Bazel module using the extension, so
    # a clash is reported here, as a clash, rather than as a duplicate
    # repository deep in bzlmod.
    claimed_names = {}
    provider_pool = {}
    module_pool = {}
    hubs = []
    for mod in module_ctx.modules:
        for tag in mod.tags.deps:
            claim_hub_name(claimed_names, tag.name, mod.name, "deps")
            roots = list(tag.roots) + ([tag.root] if tag.root else [])
            if not tag.lock and not roots:
                fail("deps tag `{}` in module `{}` names nothing: give it a `lock`, `roots`, or both".format(tag.name, mod.name))
            registry = tag.registry if tag.registry else registry_default

            provider_repos = {}
            if tag.lock:
                provider_repos = resolve_providers_from_lock_file(
                    module_ctx = module_ctx,
                    lock_file_path = tag.lock,
                    pool = provider_pool,
                    registry = registry,
                    existing_facts = existing_facts,
                    new_facts = new_facts,
                )

            module_targets = []
            if roots:
                module_targets = resolve_registry_modules(
                    module_ctx,
                    name = tag.name,
                    roots = roots,
                    registry = registry,
                    existing_facts = existing_facts,
                    new_facts = new_facts,
                    pool = module_pool,
                )

            hubs.append(struct(
                name = tag.name,
                lock = tag.lock,
                provider_repos = {
                    "{}:{}".format(source, platform): repo_name
                    for (source, platform), repo_name in provider_repos.items()
                },
                module_targets = module_targets,
            ))

    declare_provider_pool(provider_pool)
    declare_module_pool(module_pool)
    for hub in hubs:
        terraform_deps_hub(
            name = hub.name,
            lock_file_label = hub.lock,
            provider_repos = hub.provider_repos,
            module_targets = hub.module_targets,
        )

    # `reproducible = False` — module version constraints (`~> 5.0`) resolve
    # against the live Registry API and can pick different versions over
    # time. Pin every `module {}` block to an exact version to make
    # resolution deterministic; MODULE.bazel.lock captures the result either
    # way.
    kwargs = {"reproducible": False}
    if supports_facts:
        kwargs["facts"] = new_facts
    return module_ctx.extension_metadata(**kwargs)

def deps_tag_class(default_registry):
    """The `deps` tag class, documented for the given default registry.

    Args:
        default_registry: (str) Named in the `registry` attribute's docs.

    Returns:
        (tag_class)
    """
    return tag_class(
        doc = """What a root module needs from outside the workspace: the
        providers a `.terraform.lock.hcl` pins (`lock`) and the registry
        modules named by the `module` blocks in some directories (`roots`).
        Either half may be omitted. Produces the hub `@<name>`; a
        `terraform_module` that depends on it needs no `lock` attribute.
        `@<name>//:providers`, `@<name>//:modules` and
        `@<name>//<namespace>_<name>` are the parts.""",
        attrs = {
            "lock": attr.label(
                doc = """A `.terraform.lock.hcl`. Every provider it pins is fetched,
                for every platform the registry publishes, and the lock itself
                travels with the hub so the engine can verify the install.""",
                allow_single_file = [".terraform.lock.hcl"],
            ),
            "name": attr.string(
                doc = "The name of the hub repository.",
                mandatory = True,
            ),
            "registry": attr.string(
                doc = """Registry hostname to query. Empty (the default) means
                `{}`. Applies to lock entries that name a public registry and
                to `module` blocks whose source names no host; a lock entry
                or source naming another host is looked up there.""".format(default_registry),
                default = "",
            ),
            "root": attr.label(
                doc = "Shorthand for a one-element `roots`.",
                allow_single_file = [".tf"],
            ),
            "roots": attr.label_list(
                doc = """The directories whose `module { source = "…" }` blocks
                name registry modules, each given as any `.tf` file inside it.
                The file gets no special treatment: every `*.tf` in its
                directory is read, and a sibling would behave identically. Root
                modules and shared library modules both belong here, since a
                library's own `module` blocks are what reach the registry.

                Registry modules composed of other registry modules are
                followed. Archives are pooled across every hub, and a module
                depending on a hub depends on a candidate pool from which the
                init aspect installs only what its own `module` blocks name,
                so listing many directories in one hub costs nothing.

                The files need no `exports_files`. Only each label's package is
                read, so nothing resolves them as targets and a module in that
                package keeps whatever `visibility` it declares.""",
                allow_files = [".tf"],
            ),
        },
    )
