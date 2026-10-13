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

## Phase 5 — promotion-branch algorithm (pure-git simulation)

Command: `bash sf-pipeline/tests/test_promotion_sim.sh` → `All promotion simulation assertions passed` (27 assertions).

| Case | Proven |
| --- | --- |
| 1. no clobber | target `qa` has `L1-qa`, feature has `L3-feat` in the same file → promotion payload contains **both**; the merge-base payload (the feature's own file) lacks `L1-qa`, i.e. it would have clobbered it; `delta(target_sha_at_cut..HEAD)` is exactly the changed file |
| 2. conflict | a feature editing the same line exits 10, reports `conflict=true` + the conflicting path, emits an `::error::` annotation, leaves no `MERGE_HEAD` and a clean tree |
| 3. target moved | another promotion lands on the target between cut and merge → merge refused (exit 11, `merged=false`, reason "moved"), target untouched |
| 4. merge | target unchanged → merged by push; the target's tree equals the deployed tree; both `L1-qa` and `L3-feat` present; the other promotion's file kept |
| 5. protected | a push rejected by branch protection (pre-receive hook printing GH006) fails with exit 12 in `push` mode and in `auto` mode without a PR path — never reported as success |
| 6. rebuild | re-cutting from the recorded `CUT_SHA` + feature commit after the target moved again yields the identical tree hash |

## Workflows — static checks

`actionlint 1.7.12` over all 19 workflow files (17 from the spec + `ci-selftest` + `sf-auth-check`) and the local composite actions: no findings.

Hardcoded-name scan (`grep -rnwE "int|qa|stage|...|main|sfp-..."` over `.github/workflows` and `sf-pipeline`, excluding the config and tests): only the spec-mandated filename `sf-int-deploy.yml` (contents generic) and `plan.py`'s schema default for `production.name`. The `ci-selftest` trigger's `branches: [main]` was removed.

## Sample business metadata (`force-app`)

- LWC Jest: `npx sfdx-lwc-jest -- --ci` → `Tests: 2 passed, 2 total`.
- First onboarding attempt failed on every org: tests hit `No such column 'Status__c'` because the
  sample code queries `WITH USER_MODE` and deploying a field grants nobody field access. Fixed by
  running the tests as a test user holding `Invoice_User` (`InvoiceTestData` + `System.runAs`).
- `onboard-org.sh` (full deploy + tests + coverage map), all **Succeeded, 22 components, 7/7 tests**:

| Org | Deploy id |
| --- | --- |
| sfp-int | `0Afh1000000NxVdCAK` |
| sfp-qa | `0Afdq00000EQDBFCA5` |
| sfp-stage | `0AfjZ000000LDLdSAO` |
| sfp-prod | `0Afhv000000QvxBCAS` |
| sfp-dev | `0Afdq00000EQDG5CAP` |

## Connected App probe

Check-only deploy of a Connected App (throwaway cert, key deleted immediately, never uploaded) to
`sfp-int` → `Error in SFDevOps_Probe - You can't create a connected app. To enable connected app
creation, contact Salesforce Customer Support.` Consequence: CI sign-in defaults to SFDX auth URLs
(`SF_AUTH_URL` / `HUB_AUTH_URL`); JWT remains supported for orgs that have a Connected App or an
External Client App. Every org's CLI login has a shareable auth URL (checked as a boolean only;
values never printed).

## GitHub Environments

Created via the REST API: `dev`, `int`, `qa`, `stage`, `prod-validate`, and `prod` with required
reviewer `muraliseelam` (`prevent_self_review: false`).

## Hub org

`sfp-hub` created from DevHub `partner-pbo` (API 68.0, expires 2026-11-12). Metadata layer deployed
by the hub-metadata agent: objects/fields `0Afcf00000Ch5f3CAB` (266 components: 22 objects, 222
fields), credentials + custom permissions `0Afcf00000Ch5ojCAB`, object tabs `0Afcf00000Ch5rxCAB`,
layouts `0Afcf00000Ch5wnCAB`.

## Setup scripts (dry runs)

- `bootstrap_secrets.py --dry-run`: resolves `muraliseelam/sfdevops-app`, plans the 6 GitHub
  Environments (reviewer on `prod`), per-org secrets for sfp-dev/int/qa/stage/prod (prod org into
  both prod environments) and the hub's repository secrets. No value read or printed.
- `seed-pipeline.py --dry-run`: project `sfdevops-app`, 5 environments (dev source + int/qa/stage +
  prod), 4 stages in chain order with gate types Review / Self_Service / Required_Reviewer.
- `setup-branch-protection.sh --dry-run`: would create `stage`, `qa`, `int` from `main` and protect
  `main`, `stage`, `qa` (enforce_admins) and `int` (entry, not enforced).

## Test resolver, pass 1 against a live coverage map

First attempt: `ApexCodeCoverage` had 0 rows and every `ApexCodeCoverageAggregate` row read
0 lines covered: `sf apex run test` without `--code-coverage` asks the org to skip coverage.
Fixed in `onboard-org.sh`; re-ran the test classes with `--code-coverage` on all five orgs
(each: `Passed`, 7 tests, org-wide coverage 97 %).

Then, for a delta containing only `ApexClass:InvoiceTotals`:

    GITHUB_OUTPUT=out py sf-pipeline/scripts/specified_tests.py --package package.xml --source-path force-app --org sfp-int --cap 25
    tests=BillingScenarioTests,InvoiceControllerTest
    | `BillingScenarioTests` | coverage map (org sfp-int, up to 12 lines) | InvoiceTotals |
    | `InvoiceControllerTest` | coverage map (org sfp-int, up to 11 lines) | InvoiceTotals |
    Test level: RunSpecifiedTests

`BillingScenarioTests` shares no name with `InvoiceTotals`; only the coverage map finds it. Not
`RunLocalTests`, not the whole org.

## ci-selftest on GitHub runners (ubuntu-latest)

Run https://github.com/muraliseelam/sfdevops-app/actions/runs/38359797164: **success**.

- unit: `Ran 100 tests ... OK` (Python); bash suites all `0 failed`: audit_append 11, auth_hub 72,
  delta 59 (real sfdx-git-delta 6.45.1), hub_callback 53, install_sf 14, list_source_members 25,
  sonar_gate 25, webex_notify 21; `All promotion simulation assertions passed`. CLI
  `@salesforce/cli/2.153.5 linux-x64`.
- lint: actionlint clean.
- matrix: the same workflow expanded to **3** jobs for `config-3env.yml` (int, qa, stage) and
  **5** jobs for `config-5env.yml` (int, sit, qa, uat, stage), with no file change.

The first run (38359538112) failed only in the installer: it read the installed plugin version
from the human-readable `sf plugins` table, which parsed to nothing on Linux. Fixed by reading
`sf plugins --json` and allow-listing the unsigned plugin.

## Hub app — full deploy, access, seed

`tools/deploy-hub.sh sfp-hub --tests`: 10/10 steps Succeeded; Apex step **31 classes, 130/130
tests**. API checks: `AppMenuItem SF_DevOps IsAccessible=true IsVisible=true`; 17 tabs; 6 Lightning
pages; `CDO_Developer_Access = [CDO_User, CDO_Developer]`; CDO_User grants the app (TabSet),
17 visible tabs and every controller a page loads (release/data writes check Release Manager
object permissions). `grant-app-access.sh sfp-hub CDO_Admin_Access` → assigned.
`seed-pipeline.py --org sfp-hub` → project 1, environments 5, stages 4, settings set, reconciler
scheduled (4 jobs), `verified: hub matches pipeline.config.yml`.

Trap hit: scheduled Apex blocks redeploying every class it references ("This schedulable class has
jobs pending or in progress"). `deploy-hub.sh` now pauses the reconciler for the deploy and
reschedules it (verified: 4 jobs scheduled after the redeploy).

## Environment branches

`int`, `qa`, `stage` created from `main` @ 99cc96493bc2 (protection deferred until the live runs pass).

## Unlocked package

`sf package create` (no namespace) → package `0Hohm0000000VAHCA2`. `sf package version create
--code-coverage` → version **0.1.0.1 = `04thm000002tWkTAAU`**, `HasPassedCodeCoverageCheck: True`,
Apex coverage **94 %**, not yet promoted (beta). One-command install into a brand-new scratch org
(`sfp-pkgtest`, 1-day expiry): `sf package install --package 04thm000002tWkTAAU` → `SUCCESS`;
`SF DevOps 0.1.0.1` listed as installed; the `SF_DevOps` app present.

## Fixes found by review before the live runs

- Current sf CLIs redact both `accessToken` and `sfdxAuthUrl` in `sf org display` (with or
  without `--verbose`), and the redacted text is non-empty, so a presence check passes. The
  bootstrap now reads `sf org auth show-sfdx-auth-url --no-prompt` and checks `force://`
  (verified true for sfp-int and sfp-hub, boolean only). Hub callbacks and the Named Credential
  token now go through `sf api request rest` (path without a leading slash; with one it 404s),
  so no token is read anywhere. Live: an empty callback body gets the hub's own HTTP 400
  validation message, proving routing and auth.
- `gate.sh` gained tests (14 assertions) proving the entry-stage label gate without a second
  GitHub account.

## Contract #2 (inbound callbacks), live against the hub

`bash sf-pipeline/tests/smoke_hub_callbacks.sh sfp-hub` posts, through the same
`hub_payload.py` + `hub-callback.sh` (`sf api request rest`) the workflows use, the sequence a real
change produces, for a fresh `[smoke]` work item: Commit → Validation Running → Validation
Success → entry-hop Deploy Running → Deploy Success. All five returned **HTTP 200**, and:

    PASS  one CDO_Commit__c (1)
    PASS  two CDO_Component__c (2)
    PASS  ONE validation row for the Running→Success pair (1)
    PASS  ONE deploy row for the Running→Success pair (1)
    PASS  deploy row is Success (Success)
    PASS  entry-hop junction row written (1)
    PASS  entry-hop promotion Deployed (Deployed)
    PASS  work item moved to the entry stage (int)
    PASS  entry environment Healthy (Healthy)
    PASS  audit events written (5)
    Hub callback smoke test passed for WI-0001

(The first run's two "failures" were the test's own SOQL aliases on relationship fields, which
SOQL rejects outside aggregates; the records were correct. The smoke work items WI-0000 and
WI-0001 remain in the hub, labelled `[smoke]`.)

## Hub redeploy traps

- Permission sets inside a permission set group cannot be redeployed while the group
  recalculates ("The ... permission set group is updating"); `deploy-hub.sh` now waits for every
  `CDO_*` group to be `Updated` before steps 9 and 10.
- `CDO_WorkItemService.openPullRequest` now writes `Specified-Tests: <tests>` first in the PR
  body when the work item names tests, so the work item's explicit tests reach validation.
  Redeployed with 130/130 tests.
