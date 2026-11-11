"""The environment a rule's attributes add to the engine's."""

ENV_ATTRS = {
    "env": attr.string_dict(
        doc = """Environment variables for the engine, set over the host's
        for a run and over the hermetic one for a test: `TF_VAR_<name>`
        for a root keyed on an input variable, `TF_LOG`, `TF_CLI_ARGS_plan`.
        Values are literal. `TF_WORKSPACE` here and `workspace` must
        agree.""",
    ),
    "workspace": attr.string(
        doc = """Run in this Terraform workspace, over anything the
        environment or `--test_env` sets. Unset, the environment's
        `TF_WORKSPACE` applies, else `default`. One test per workspace is
        how a root keyed on `terraform.workspace` gets each one checked,
        and one binary per workspace runs it with no `workspace select`
        first.""",
    ),
}

# The test rules add `env_inherit`. A binary has no use for it: `bazel run`
# hands the executable the whole client environment, where `bazel test`
# starts from a scrubbed one.
TEST_ENV_ATTRS = dict(ENV_ATTRS, **{
    "env_inherit": attr.string_list(
        doc = """Variables the test takes from the environment `bazel test`
        ran in, `AWS_PROFILE` say. The variables tests scrub for
        hermeticity (the CLI configuration ones) cannot be inherited, and
        the runner says so.""",
    ),
})

def engine_env(ctx):
    """The variables `env` and `workspace` set for the engine.

    Args:
        ctx: (ctx) A rule context with `ENV_ATTRS` or `TEST_ENV_ATTRS`.

    Returns:
        (dict[str, str]) Variables to set over the engine's environment.
    """
    env = dict(ctx.attr.env)
    for key in env.keys() + getattr(ctx.attr, "env_inherit", []):
        if key.startswith("RULES_TERRAFORM_"):
            fail("{}: `{}` is the runner's own; it belongs in neither `env` nor `env_inherit`".format(ctx.label, key))
    if ctx.attr.workspace:
        if env.get("TF_WORKSPACE", ctx.attr.workspace) != ctx.attr.workspace:
            fail("{}: `workspace` is \"{}\" but `env` sets TF_WORKSPACE to \"{}\"; set one of them".format(ctx.label, ctx.attr.workspace, env["TF_WORKSPACE"]))
        env["TF_WORKSPACE"] = ctx.attr.workspace
    return env
