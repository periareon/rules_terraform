"""The `tofu` bzlmod extension.

One extension, two tag classes:

* `toolchain` — pins the OpenTofu release the build uses, any release,
  not only the ones shipped in `//tofu/private:versions.bzl`. Root
  module only; without it the newest shipped release is used. The
  extension always materializes `@tofu_toolchains`, a hub declaring a
  toolchain per platform for that release, and `@tofu`, the CLI hub.
  rules_terraform's own `MODULE.bazel` `use_repo`s the toolchain hub and
  `register_toolchains`s it, so downstream users get toolchain resolution
  for free.
* `deps` — the providers a lock file pins and the registry and git modules
  some directories' `module` blocks name, as one hub per tag. Fetched
  archives go into one pool shared by every hub, keyed by what the archive
  is rather than who asked for it; each hub is an alias layer over that pool.

The body is `//engine:extension_impl.bzl`, shared with the other engine.
Everything OpenTofu-specific is in `//tofu/private:engine.bzl`.
"""

load("//engine:extension_impl.bzl", "deps_tag_class", "run_extension")
load("//engine:toolchain_extension.bzl", "toolchain_tag_class")
load("//tofu/private:engine.bzl", "TOFU_ENGINE")

def _tofu_impl(module_ctx):
    return run_extension(module_ctx, engine = TOFU_ENGINE)

tofu = module_extension(
    doc = """The OpenTofu extension: a `toolchain` tag pins the engine release,
    `deps` tags describe a module's external dependencies. Always
    materializes `@tofu_toolchains` and `@tofu`; `deps` defaults to
    `registry.opentofu.org`.""",
    implementation = _tofu_impl,
    tag_classes = {
        "deps": deps_tag_class(TOFU_ENGINE.registry),
        "toolchain": toolchain_tag_class(TOFU_ENGINE.name),
    },
)
