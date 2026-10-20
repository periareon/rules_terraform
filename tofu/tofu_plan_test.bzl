"""tofu_plan_test"""

# buildifier: disable=bzl-visibility
load("//tofu/private:engine_rules.bzl", _tofu_plan_test = "tofu_plan_test")

def tofu_plan_test(name, tags = [], **kwargs):
    """Runs a real `tofu plan` as a test and keeps the plan for review.

    A thin wrapper over the rule of the same name that adds the
    `requires-network` tag: a plan reaches the state backend and, for most
    providers, the provider's API. Credentials come from the environment, so
    pass them with `--test_env`. Providers that work offline (`null`,
    `local`, `random`) need neither.

    See the rule's documentation for the attributes and the artefacts left in
    the undeclared test outputs directory.

    Args:
        name: (str) Target name.
        tags: (list[str]) Extra tags. `requires-network` is always added.
        **kwargs: Forwarded to the rule: `root`, `plan_args`,
            `expect_no_changes`, `lock`, and the usual test attributes.
    """
    _tofu_plan_test(
        name = name,
        tags = tags + (["requires-network"] if "requires-network" not in tags else []),
        **kwargs
    )
