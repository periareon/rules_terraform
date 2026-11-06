"""tofu_plan_test"""

load("//tofu/private:engine_rules.bzl", _tofu_plan_test = "tofu_plan_test")

def tofu_plan_test(name, tags = [], **kwargs):
    """Runs `tofu plan` as a test and keeps the plan for review.

    The rule of the same name, tagged `requires-network`: a plan reaches the
    backend and the provider APIs, with credentials from `--test_env`.

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
