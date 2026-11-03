"""The body of the `terraform` and `tofu` module extensions.

Both carry two tag classes. `toolchain` picks engine releases beyond the
shipped table and is handled by `toolchain_extension.bzl`. `deps` describes
what modules need from outside the workspace and is handled here. The
engines differ only in their `engine_config`: the release location, and
which registry a tag that names none is resolved against,
`registry.terraform.io` for `terraform`, `registry.opentofu.org` for `tofu`.
Everything else — reading lock files, pooling archives, resolving registry
modules, recording facts — is shared.

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
load(":toolchain_extension.bzl", "declare_toolchains")

visibility(["//engine/...", "//terraform/...", "//tofu/..."])

UPGRADE_ENV = "RULES_TERRAFORM_UPGRADE"

def run_extension(module_ctx, *, engine):
    """Evaluate every `toolchain` and `deps` tag and declare their repositories.

    Args:
        module_ctx: (module_ctx) The extension context.
        engine: (struct) The `engine_config`. Its `registry` is queried
            when a tag leaves `registry` empty: for lock entries that name
            a public registry, and for `module` blocks whose source names
            no host. Its `hub_bzl` is what the generated repositories load
            their rules from.

    Returns:
        (extension_metadata) `reproducible = True`, carrying this
        evaluation's facts: release checksums, provider lookups, module
        archives, and the version each constraint and git ref resolved to.
    """
    supports_facts = hasattr(module_ctx, "facts")
    existing_facts = module_ctx.facts if supports_facts else None
    new_facts = {}

    # `terraform init -upgrade`, for the resolutions this extension records:
    # set to re-resolve every version constraint and git ref. Read through
    # the context so toggling it is an input change and the extension runs.
    upgrade = bool(module_ctx.getenv(UPGRADE_ENV))

    declare_toolchains(module_ctx, config = engine, existing_facts = existing_facts, new_facts = new_facts)

    # Every hub is resolved before anything is declared: the pools are
    # shared, and a hub cannot know what another will add to them. Hub names
    # share one namespace across every Bazel module using the extension, so
    # a clash is reported here, as a clash, rather than as a duplicate
    # repository deep in bzlmod.
    claimed_names = {}
    for reserved in ["{}_toolchains".format(engine.name), engine.cli_hub]:
        claim_hub_name(claimed_names, reserved, "rules_terraform", "toolchain")
    provider_pool = {}
    module_pool = {}
    hubs = []
    for mod in module_ctx.modules:
        for tag in mod.tags.deps:
            claim_hub_name(claimed_names, tag.name, mod.name, "deps")
            roots = list(tag.roots) + ([tag.root] if tag.root else [])
            if not tag.lock and not roots:
                fail("deps tag `{}` in module `{}` names nothing: give it a `lock`, `roots`, or both".format(tag.name, mod.name))
            registry = tag.registry if tag.registry else engine.registry

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
                    upgrade = upgrade,
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

    declare_provider_pool(provider_pool, hub_bzl = engine.hub_bzl)
    declare_module_pool(module_pool, hub_bzl = engine.hub_bzl)
    for hub in hubs:
        terraform_deps_hub(
            name = hub.name,
            lock_file_label = hub.lock,
            provider_repos = hub.provider_repos,
            module_targets = hub.module_targets,
            hub_bzl = engine.hub_bzl,
        )

    # Reproducible: every answer that came from the network is a fact now,
    # the resolution of a version constraint or git ref included, so the same
    # inputs and the same facts declare the same repositories. The first
    # evaluation of a new reference is the only live one; the next is read
    # from `MODULE.bazel.lock`, until `RULES_TERRAFORM_UPGRADE` asks again.
    kwargs = {"reproducible": True}
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
        providers a `.terraform.lock.hcl` pins (`lock`) and the registry and
        git modules named by the `module` blocks in some directories (`roots`).
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
                name registry or git modules (`git::…`, `git@…`, `github.com/…`,
                pinned with `?ref=` to a tag or full commit id; a branch is
                refused), each given as any `.tf` file inside it.
                The file gets no special treatment: every `*.tf` in its
                directory is read, and a sibling would behave identically. Root
                modules and shared library modules both belong here, since a
                library's own `module` blocks are what reach the registry.

                Modules composed of other registry or git modules are
                followed. Fetches are pooled across every hub, and a module
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
