# Build log — Session 1 (started 2026-10-13 00:30 CDT)

Evidence for each phase: the exact command and its real output (trimmed to the relevant lines).

## Phase 1 — skeleton, config, plan.py

Command:

    py -m unittest discover -s sf-pipeline/tests -p "test_plan.py" -v

Result: `Ran 23 tests ... OK`. The same `plan.py` resolves:

- `fixtures/config-3env.yml` — chain `int → qa → stage → prod`, branches `int/qa/stage/main`
- `fixtures/config-5env.yml` — chain `int → sit → qa → uat → stage → production`, branches
  `env/*`, different source path, baseline, release prefix and gates

Covered: all four spec modes (`outputs`, `resolve`, `promote`, `target`) plus `source`;
`normalize_envs` defaults (`test_level` → `RunSpecifiedTests`, `gh_environment` → name);
`r_is_entry` true only on the first environment; a PR into the prod branch validates in the
reviewer-free environment; the entry environment refuses a whole-branch promotion; config
validation (duplicate branches, bad test level, prod branch reused, bad delta mode, same
deploy/validate environment).

Real config (`py sf-pipeline/scripts/plan.py outputs`), key lines:

    env_count=3
    env_names=int qa stage
    entry_branch=int
    prod_branch=main
    prod_validate_environment=prod-validate
    destructive_tests=PipelineCanaryTest
    protected_branches=main stage qa int
