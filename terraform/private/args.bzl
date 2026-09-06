"""Helper for building JSON-shaped action args that Bazel can path-map.

## Why this exists

Actions that need *structured* input — nested objects with File fields, e.g.
a list of provider objects each with a `dir_path` pointing at a provider
install directory — can't cleanly express that shape via flat CLI flags.
Encoding structure as parallel `-provider-source=... -provider-version=...`
lists is fragile (order-correlation) and encoding as a single delimited
string (`-provider=source|version|dir`) is separator-fragile.

Historically the JSON-using tools in this repo have hand-written the args
file via `ctx.actions.write(args_file, json.encode(dict))`. That works but
it defeats Bazel path mapping: the paths are baked into a text file at
analysis time, not routed through `ctx.actions.args()`. Under
`--experimental_output_paths=strip` the args file stays literal while the
rest of the action's files get their paths rewritten, so the tool receives
a mix of stale and mapped paths — or, more subtly, actions that would
otherwise share a cache entry across configurations don't.

## The two-file design

`write_json_args` splits the args into a pair of files:

* A **JSON template**, written with `ctx.actions.write` (pure text). Every
  `File` in the input tree is replaced with a `"<<RTF_PATH_N>>"` placeholder
  string. Non-File scalars (str/int/bool/None) are serialized as-is.

* A **paths file**, written with `ctx.actions.write(..., content = args)`
  from a `ctx.actions.args()` object holding the Files in order. Bazel
  path-maps every entry in that Args object when path mapping is on.
  Line `N` corresponds to placeholder `<<RTF_PATH_N>>` in the template.

The consuming Go tool calls `argsjson.LoadInto(templatePath, pathsPath,
&spec)` — see `//terraform/private/internal/argsjson`. It reads both
files and substitutes the placeholders, recovering a JSON document with
Bazel-mapped paths that unmarshals into whatever struct the tool expects.

## Usage

    load("//terraform/private:args.bzl", "build_file_manifest", "write_json_args")

    args_data = {
        "output_dir": terraform_dir,      # File -> placeholder
        "source_files": root_srcs,        # list[File] -> list of placeholders
        "lock_file": lock_file,           # File or None
        "providers": [
            {
                "source": "hashicorp/null",
                "version": "3.2.4",
                "platform": "linux_amd64",
                # Copy manifest — each entry is `{"src": File, "dst": str}`.
                # The Go tool copies `src` (path-mapped by Bazel) to
                # `installDir/dst`. No walking, no filepath.Rel, no
                # reliance on sandbox semantics.
                "files": build_file_manifest(
                    provider_files,
                    "provider {}".format(provider_source),
                ),
            },
            ...
        ],
    }
    template, paths_file = write_json_args(ctx, "init", args_data)
    ctx.actions.run(
        executable = ctx.executable._init,
        arguments = ["-args=" + template.path, "-paths=" + paths_file.path],
        inputs = depset([template, paths_file], transitive = [provider_files_depset]),
        outputs = [terraform_dir],
    )

The Files inside `args_data` do NOT need to be listed as action inputs
themselves via this call — they still need to be in the action's `inputs`
depset (through their normal transitive-files channels), but
`write_json_args` doesn't add them there. This is deliberate: the helper
shouldn't second-guess the caller's input graph.
"""

visibility(["//opentofu/...", "//terraform/...", "//tests/..."])

_PLACEHOLDER_FMT = "<<RTF_PATH_{}>>"

# Runaway-loop backstop. Starlark forbids recursion so the walker is a
# bounded loop over a work stack; this cap is deliberately far above any
# realistic args tree.
_MAX_WALK_ITERATIONS = 100000

def _pick_root_file(files, context):
    """Return the file that lives directly at the shared root of `files`.

    Used to pick a representative File from a provider's or module's install
    tree so the consuming tool can derive the root directory via
    `filepath.Dir(picked)`. Files split across multiple directories still
    share a common root; this helper enforces that invariant loudly rather
    than silently returning a file whose parent is a subdirectory.

    Args:
        files: (list[File]) A non-empty list of File objects that should
            share a common root directory.
        context: (str) Human-readable label for the fail message (e.g.
            the provider source or module key) so operators can locate
            the offending target.

    Returns:
        (File) A File whose `dirname` is the shared root — the
        shallowest-depth file in the list. Fails if `files` is empty or
        contains a file that doesn't live under that root.
    """
    if not files:
        fail("{}: _pick_root_file needs at least one file".format(context))

    # Single pass: pick the shallowest file and validate every deeper file
    # lives under its dirname. Depth is cached — `path.count("/")` on every
    # comparison was O(N·L) for aspect-hot paths.
    root_file = files[0]
    root_depth = root_file.path.count("/")
    for f in files[1:]:
        d = f.path.count("/")
        if d < root_depth:
            root_file = f
            root_depth = d

    root_dir = root_file.dirname
    for f in files:
        if f.dirname == root_dir:
            continue
        if not f.dirname.startswith(root_dir + "/"):
            fail("{}: file {} does not live under the shared root {}".format(
                context,
                f.path,
                root_dir,
            ))
    return root_file

def build_file_manifest(files, context):
    """Return a `[{"src": File, "dst": str}, ...]` copy manifest.

    Each `dst` is the file's position relative to the shared root that
    `_pick_root_file` locates. The consuming Go tool just does
    `filepath.Join(installDir, dst)` and copies — no walking, no
    `filepath.Rel`, no reliance on Bazel sandbox semantics to filter
    undeclared siblings.

    Args:
        files: (list[File]) A non-empty list of File objects that share a
            common root directory (invariant validated by `_pick_root_file`).
        context: (str) Human-readable label for fail messages.

    Returns:
        (list[dict]) One entry per input file. `src` is the File itself
        (`write_json_args` swaps it for a path-mapped placeholder); `dst`
        is the forward-slash relative path from the shared root.
    """
    root_file = _pick_root_file(files, context)
    root_prefix = root_file.dirname + "/"
    manifest = []
    for f in files:
        if not f.path.startswith(root_prefix):
            # _pick_root_file already validated this via dirname prefix
            # checks; catching the string-slice edge case here just makes
            # the failure explicit if something upstream ever violates it.
            fail("{}: file {} not under {}".format(context, f.path, root_file.dirname))
        manifest.append({"dst": f.path[len(root_prefix):], "src": f})
    return manifest

def _placeholder(f, files_out):
    idx = len(files_out)
    files_out.append(f)
    return _PLACEHOLDER_FMT.format(idx)

def _walk(root, files_out):
    """Iteratively replace every File in `root` with a placeholder string.

    Starlark forbids recursion, so this is a manual post-order walk driven
    by a work stack. Each stack entry is `(container, key_or_index, value)`
    — we substitute in-place on the newly-built container copies. The
    outermost container is a single-element list wrapping the caller's
    root so the same substitution machinery handles both scalar and
    container tops.
    """
    holder = [None]
    stack = [(holder, 0, root)]

    for _ in range(_MAX_WALK_ITERATIONS):
        if not stack:
            return holder[0]
        container, key, node = stack.pop()

        t = type(node)
        if t == "File":
            container[key] = _placeholder(node, files_out)
        elif t == "list" or t == "tuple":
            new_list = list(node)
            container[key] = new_list
            for i in range(len(new_list)):
                stack.append((new_list, i, new_list[i]))
        elif t == "dict":
            new_dict = {}
            for k, v in node.items():
                new_dict[k] = v
            container[key] = new_dict
            for k in new_dict.keys():
                stack.append((new_dict, k, new_dict[k]))
        else:
            # Scalar (str / int / bool / NoneType). Pre-copied by the
            # parent, nothing to do.
            pass

    fail("write_json_args: exceeded {} iterations walking the args tree; likely a cyclic or absurdly deep structure".format(_MAX_WALK_ITERATIONS))

def write_json_args(ctx, name, data):
    """Build a JSON template + a path-mapped paths file for an action.

    Args:
        ctx: (ctx) The rule or aspect ctx.
        name: (str) Base filename (without extension). The two outputs
            are declared as `<name>.args.json` and `<name>.args.paths`.
        data: (dict|list|tuple|str|int|bool|None|File) A tree that may
            contain File objects at any depth. Files are replaced with
            `<<RTF_PATH_N>>` placeholders in the JSON template; their
            actual paths land in the paths file at line N through a
            `ctx.actions.args()` object so Bazel path mapping applies.

    Returns:
        (tuple[File, File]) `(template_file, paths_file)`. Both must be
        in the action's `inputs` (or in the executable's runfiles).
        Callers still need to include the referenced Files' contents in
        the action's input graph via their normal channels; this helper
        only wires up the paths.
    """
    files_in_order = []
    template = _walk(data, files_in_order)

    template_file = ctx.actions.declare_file("{}.args.json".format(name))
    ctx.actions.write(
        output = template_file,
        content = json.encode_indent(template),
    )

    paths_args = ctx.actions.args()
    paths_args.set_param_file_format("multiline")
    paths_args.add_all(files_in_order)
    paths_file = ctx.actions.declare_file("{}.args.paths".format(name))
    ctx.actions.write(
        output = paths_file,
        content = paths_args,
    )

    return template_file, paths_file
