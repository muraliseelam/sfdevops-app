# Acceptance checklist (spec §16)

Each criterion, its current status, and the evidence. **Verified** means a command or run whose
output is recorded in `docs/build-log/`. **Live run pending** means the logic is built and tested
below the live level, and the end-to-end GitHub Actions run against the orgs is waiting for the
org credentials (`bootstrap_secrets.py`, run by the maintainer). This file is updated as each live
run lands; nothing here is marked verified on the strength of code review alone.

Status as of 2026-10-13 04:00 CDT.

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | 3 → 5 environments needs no other file change; the deploy matrix adapts | **Verified** | `ci-selftest` run [38359797164](https://github.com/muraliseelam/sfdevops-app/actions/runs/38359797164): the same workflow expanded to 3 jobs for `config-3env.yml` and 5 for `config-5env.yml`; `test_plan.py` (23 tests) resolves both with the same code |
| 2 | A feature PR into the entry branch runs delta → PMD/Sonar → check-only deploy and posts a manifest comment | Live run pending | Local rehearsal against `sfp-int`: delta = 2 changed classes, resolver picked their tests, check-only validate `0Afh1000000NywLCAS` **Succeeded**, report parsed 100 % coverage (session-1 log). Workflow: `sf-pr-validation.yml` (actionlint clean) |
| 3 | A developer cannot self-approve the entry stage: `approved` is removed with a comment | Verified by tests; live needs a second (non-admin) GitHub account | `test_gate.sh` (14 assertions): write/triage/unknown are not admin, the role is asked of the API at run time, the labeler is the last one to add the label, `drop-label` removes it and comments. `sf-int-deploy.yml` ctx job applies it on the entry stage only |
| 4 | An admin approval (review or label) automatically starts the entry-hop promotion | Live run pending | `sf-pr-approved.yml` calls `sf-int-deploy.yml` after recording the approval, held back only by a failed or low-coverage validation of the head commit |
| 5 | Every hop cuts a promotion branch from the target, merges the feature, deploys `delta(promotion vs target)`, and merges only after the deploy succeeds | Algorithm **verified**; live run pending | `test_promotion_sim.sh` cases 1 and 4 (27 assertions total, green on Linux in CI); `promote` action + `deploy` action wired in `sf-int-deploy`, `sf-promotion`, `sf-promote`, `sf-prod-release` |
| 6 | Drift test: the target's own change survives a promotion touching the same file | **Verified** (simulation); live pending | Simulation case 1: payload has `L1-qa` and `L3-feat`; the merge-base payload would have lost `L1-qa` |
| 7 | A conflicting promotion aborts, comments the paths, fails, and marks the work item blocked | Abort/fail/paths **verified**; comment and hub status live pending | Simulation case 2 (exit 10, paths, `::error::`, no MERGE_HEAD); hub `CDO_CallbackService` Conflict handling covered by `CDO_Tests` |
| 8 | If the target moves mid-run, the post-deploy merge refuses | **Verified** (simulation); live pending | Simulation case 3 (exit 11, `merged=false`, target untouched); under protection, strict status checks make GitHub refuse too |
| 9 | A one-class change runs only that class's tests | **Verified** | Live resolver against `sfp-int`'s coverage map: `InvoiceTotals` → `BillingScenarioTests, InvoiceControllerTest`; `InvoiceService` → 4 tests. Never `RunLocalTests`. `test_specified_tests.py` (19 tests) |
| 10 | A class with no covering test fails validation and is refused by production | Logic **verified**; live pending | Resolver leaves the level empty and names the class (unit tests); the deploy action fails check-only, refuses production, warns + NoTestRun in sandboxes |
| 11 | Coverage below the threshold fails the deploy; the bypass label works only for an admin, re-verified at run time | Logic **verified**; live pending | `test_deploy_report.py` (gate only when on and Apex changed); bypass verified via `gate.sh is-admin` at run time in both PR workflows |
| 12 | A prod release validates in prod-validate, waits on a required reviewer, quick-deploys the validated id, then merges, tags and releases | Live run pending | `sf-prod-release.yml`: validate job in `prod-validate`; deploy job in `prod` (required reviewer `muraliseelam` configured via API); tree-identity check before the quick deploy |
| 13 | Every deploy writes `CDO_Deployment__c` + `CDO_Audit_Event__c`; Running→Success leaves one row | **Verified live at the hub** (callbacks through the real REST endpoint); GitHub-run pending | `smoke_hub_callbacks.sh sfp-hub`: Commit → Validation Running/Success → Deploy Running/Success, all HTTP 200, **one** validation row and **one** deploy row, 5 audit events (session-1 log). `CDO_Tests` (63 methods) cover the no-run-URL case |
| 14 | Every promotion writes `CDO_Promoted_Work_Item__c` junction rows | **Verified** (hub tests + live entry-hop callback) | Live: the entry-hop callback wrote the promotion + junction row, both `Deployed`, and moved the work item to `int`. `CDO_Tests`: junction rows for `requestPromotion` (1 and 3 work items), command-center actions, the entry hop, and a repair path |
| 15 | The App Launcher shows the app for a user holding only `CDO_Developer_Access`, and every tab opens | Grants **verified by API**; click-through pending | `AppMenuItem SF_DevOps` accessible/visible; 17 tabs; 6 pages; `CDO_Developer_Access = CDO_User + CDO_Developer`; CDO_User grants the app, 17 visible tabs and every controller a page loads. A visual click-through by the maintainer is still to do |
| 16 | `profiles_mode: incremental` strips a profile to in-delta permissions while keeping `userPermissions` | **Verified** | `test_profiles.py` (12 tests) |
| 17 | A destructive-only change deploys to prod using the canary test | Logic built; live pending | Deploy action: production + no Apex added → `RunSpecifiedTests PipelineCanaryTest` |
| 18 | Nothing in `.github/workflows/` or `sf-pipeline/` hardcodes an environment or branch name | **Verified** | Name scan (session-1 log): only the spec-mandated filename `sf-int-deploy.yml` (contents generic) and `plan.py`'s schema default for `production.name` |

## Also verified

- The hub app deploys in order with **130/130 tests** (`tools/deploy-hub.sh sfp-hub --tests`), is
  seeded from the YAML (`seed-pipeline.py`: "hub matches pipeline.config.yml"), and installs as an
  unlocked package (`04thm000002tWkTAAU`, 94 % coverage) into a fresh org in one command.
- All five pipeline orgs were brought to the baseline (22 components, 7/7 tests each).
- `ci-selftest` on GitHub runners: 100 Python tests, every bash suite, actionlint, all green
  ([38361283026](https://github.com/muraliseelam/sfdevops-app/actions/runs/38361283026)).

## Live runs still to do

See `docs/build-log/e2e-runbook.md` for the scenario list. They need, in order:
1. The maintainer runs `py sf-pipeline/scripts/bootstrap_secrets.py` (sets every org and hub
   secret and stores the GitHub token in the hub; prints no secret).
2. `sf-auth-check` green.
3. Scenarios 1–19 of the runbook; then `setup-branch-protection.sh` last.
