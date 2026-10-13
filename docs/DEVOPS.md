# DevOps reference

For platform operators: every workflow, composite action and script, the configuration and secrets
references, the concurrency model, and the procedures for changing the platform itself. Installation
is in [SETUP.md](SETUP.md); the integration contracts are in [CONTRACTS.md](CONTRACTS.md).

Everything here is read from the code on `main` (`.github/workflows/`, `sf-pipeline/`) and the hub
app on `platform/sfdevops-app`. End-to-end behaviour against live orgs is **Evidence: pending live
run** unless a test is named.

---

## Contents

- [Moving parts](#moving-parts)
- [Workflows](#workflows)
- [Composite actions](#composite-actions)
- [Scripts](#scripts)
- [Config reference](#config-reference)
- [Secrets reference](#secrets-reference)
- [Concurrency model](#concurrency-model)
- [Adding an environment](#adding-an-environment)
- [Adding a source org](#adding-a-source-org)
- [Updating pipeline files on protected branches](#updating-pipeline-files-on-protected-branches)
- [Observability](#observability)
- [Pinned versions](#pinned-versions)

---

## Moving parts

```text
.github/workflows/        17 pipeline workflows + sf-auth-check + ci-selftest
sf-pipeline/
  pipeline.config.yml     the only file a project edits
  deploy/action.yml       auth → delta → profiles → tests → manifest → validate/deploy/quick → report
  promote/action.yml      promotion branch: cut (merge + conflict gate) and merge (pinned, protected-aware)
  quality/action.yml      PMD, LWC Jest, SonarQube, each only when its component type changed
  report/action.yml       job summary + one sticky PR comment per environment and kind
  config/                 PMD ruleset, commit deny-list
  scripts/                the algorithms (plan.py, delta.sh, promote.sh, specified_tests.py, ...)
  tests/                  unit tests, bash tests, the promotion simulation, fixtures
  connected-app/          reference Connected App for JWT mode
```

Every workflow starts with a `plan` step that runs `python3 sf-pipeline/scripts/plan.py` and consumes
its outputs, so no workflow names an environment, branch or org count. Every terminal state POSTs a
callback to the hub through `hub-notify.sh` (skipped with a notice when no `HUB_*` secret is set).

---

## Workflows

### Summary

| Workflow | Trigger | Deploys to | Concurrency group |
| --- | --- | --- | --- |
| `sf-commit` | `workflow_dispatch` (hub) | — (retrieves from a source org) | `sf-commit-<feature branch>` |
| `sf-list-changes` | `workflow_dispatch` (hub) | — | — |
| `sf-open-pr` | `workflow_dispatch` (hub) | — | — |
| `sf-pr-validation` | `pull_request` opened / synchronize / reopened / ready_for_review; `workflow_dispatch` | check-only, the PR base's environment | `sf-pr-validation-<PR>` (cancel in progress) |
| `sf-pr-approved` | `pull_request_review` submitted (approved); `pull_request` labeled | calls `sf-int-deploy` | — |
| `sf-int-deploy` | `workflow_call` (from `sf-pr-approved`); `workflow_dispatch` | the PR base's environment (normally the entry) | `sf-deploy-<branch>` |
| `sf-promotion` | `workflow_dispatch` (hub queue); `workflow_call` | any non-production environment | `sf-deploy-<branch>` |
| `sf-promote` | `workflow_dispatch`; `workflow_call` (from `sync-env-branches`) | any non-production environment | `sf-deploy-<branch>` |
| `sf-prod-release` | `workflow_dispatch` (hub release board) | production (validate, then quick deploy) | `sf-prod-release` |
| `assemble-release` | `schedule` 05:41 UTC Mon–Fri; `workflow_dispatch` | — (builds `release/<name>`) | `assemble-release` |
| `auto-merge-approved` | `workflow_dispatch` | — (merges green promotion PRs) | — |
| `sf-conflict-check` | `push` (any branch; the job continues only for feature branches), `schedule` every 3 h Mon–Fri at :23, `workflow_dispatch` | — | `sf-conflict-check` (cancel in progress) |
| `sf-data-deploy` | `workflow_dispatch` (hub data deployer) | records into the target org | — |
| `sf-ops-rollback` | `workflow_dispatch` (hub governance) | the named environment, production included | `sf-deploy-<branch>` |
| `sf-ops-redeploy-feature` | `workflow_dispatch` | calls `sf-promotion` | `sf-deploy-<branch>` |
| `sf-ops-recreate-feature` | `workflow_dispatch` | — (rewrites a feature branch) | — |
| `sync-env-branches` | `workflow_dispatch` | calls `sf-promote` per environment | `sf-deploy-<branch>` |
| `sf-auth-check` | `workflow_dispatch` | — (`sf org display` per org) | — |
| `ci-selftest` | `push` / `pull_request` touching `sf-pipeline/**` or `.github/**`; `workflow_dispatch` | — (no secrets) | — |

All inputs are strings (the hub's dispatch contract requires it). Blank means "use the default".

### `sf-commit` — retrieve selected components into the feature branch

- **Inputs:** `work_item` (required), `work_item_id`, `source_org` (a `source_orgs` key, required),
  `components` (JSON array `[{"type":"ApexClass","name":"Foo"},{"type":"ApexClass","name":"Old","action":"Delete"}]`,
  required), `commit_message` (required), `feature_branch` (blank = feature prefix + work item).
- **Jobs:** `plan` (`plan.py outputs`, `plan.py source <org>`) → `commit` in the source org's GitHub
  Environment: authenticate, check out or cut the feature branch from the baseline, build a
  retrieve manifest with `commit_helper.py package` (deny-list applied), `sf project retrieve start`,
  apply deletions, commit `[<WI>] <message>`, push, list touched components with
  `commit_helper.py payload`.
- **Writes back:** `Commit` event with `components` → `CDO_Commit__c` (upsert on SHA),
  `CDO_Component__c` (upsert on `<WI>|<Type:Member>`), work item `Committed`.
- **Permissions:** `contents: write`. Pushes with `GH_PAT` when set.

### `sf-list-changes` — the commit screen's change list

- **Inputs:** `work_item`, `work_item_id`, `source_org` (required), `request_id`.
- **Jobs:** `plan` → `list` in the source org's environment: `list-source-members.sh` queries
  `SourceMember` (Tooling API), newest first.
- **Writes back:** `POST /cdo/source-members` with the members (`Source_Changes_JSON__c`,
  `Source_Changes_Status__c` = Received or Failed).
- **Permissions:** `contents: read`.

### `sf-open-pr` — open the feature → entry PR

- **Inputs:** `work_item` (required), `work_item_id`, `feature_branch`, `title`, `body`.
- **Job:** opens (or reuses) the PR into `entry_branch` with `GH_PAT || GITHUB_TOKEN`; title
  `[<WI>] <title>`; body ends with the Specified-Tests hint. Without `GH_PAT` it warns and dispatches
  `sf-pr-validation` itself (a PR opened with `GITHUB_TOKEN` does not trigger workflows).
- **Writes back:** `PullRequest` event → PR URL and number, review state `Pending`, status `In_Review`.
- **Permissions:** `contents: read`, `pull-requests: write`, `actions: write`.

### `sf-pr-validation` — delta → quality → check-only deploy

- **Inputs (dispatch):** `pr_number` (required), `work_item`, `work_item_id`.
- **Jobs:**
  - `plan`: reads the PR (`gh pr view`), extracts `Specified-Tests:` from the body, resolves the base
    branch (`plan.py resolve`). Skips (notice) when the base is not a pipeline branch, the head is a
    promotion branch, the PR is a draft, or it comes from a fork (no secrets). Derives the work item
    key from the feature branch, else the title, else `PR-<n>`. Re-verifies the bypass label.
  - `changes`: in target mode, `promote` `mode: cut` from the base with the PR head merged in (a
    conflict comments the paths and reports `Conflict`); in baseline mode, the PR head against
    `origin/<baseline_branch>`. Runs `delta.sh`, renders the manifest, uploads artifact
    `delta-pr-<n>` (14 days).
  - `quality` (only when Apex, LWC or JS changed): rebuilds the identical tree with
    `promote.sh cut` and `CUT_SHA`, runs the quality action (advisory under bypass), uploads
    `findings-pr-<n>`.
  - `validate` (in the resolved GitHub Environment; `prod-validate` for a PR into production):
    rebuilds the tree, callback `Running`, check-only deploy through the deploy action, sticky
    report, callback with the result and findings.
- **Writes back:** `Validation` events (deployment row with `Check_Only__c`, work item
  `Last_Coverage__c`, `Last_Tests_Passed__c`, `Last_Validation_Status__c`, `Last_Run_URL__c`,
  `CDO_Scan_Finding__c` rows); `Conflict` on a merge conflict.
- **Permissions:** `contents: read`, `pull-requests: write`, `issues: write`.

### `sf-pr-approved` — approval starts the entry deploy

- **Triggers:** an approving review, or any label (the job proceeds only for `approved_label`).
- **Jobs:**
  - `approval`: resolves the base; refuses production (released by `sf-prod-release`) and promotion
    PRs; computes method (`review` / `label`) and approver. **Hold check:** reads the PR's comments
    for the hidden marker `<!-- sfdevops:validation sha=<head> outcome=… coverage=… -->`; the hold
    reason is set when no validation reported for the head commit, the latest one did not pass, or
    coverage is below `coverage_threshold`. Callback `Approval` (the hold reason in `message`).
  - `deploy`: `uses: ./.github/workflows/sf-int-deploy.yml` with `secrets: inherit`.
- **Note:** GitHub runs `pull_request_review` workflows from the PR's base branch, so this file and
  everything it calls must exist on every environment branch.
- **Permissions:** `contents: write`, `pull-requests: write`, `issues: write`, `statuses: write`.

### `sf-int-deploy` — the gated entry deploy

The filename keeps the specification's name; the contents are generic: it deploys to whatever
environment the PR's base branch resolves to.

- **Inputs:** `pr_number` (required), `work_item`, `work_item_id`, `approver` (blank = the actor),
  `method` (`review` / `label` / `manual`), and from `sf-pr-approved` only, `hold_reason`.
- **Jobs:**
  - `ctx`: reads the PR, resolves the base. **Gate:** the PR must be open and target a pipeline,
    non-production branch. On the **entry** stage, `label` counts only when `gate.sh is-admin`
    confirms admin/maintain (otherwise the label is removed with a comment and nothing runs);
    `manual` needs admin/maintain; `review` always counts. A `hold_reason` comments on the PR and
    stops. Re-verifies the bypass label.
  - `deploy` (environment of the base; group `sf-deploy-<branch>`): callback `Running`, promote cut,
    deploy, promote merge only on `success` / `no_changes`, merge-status callback, sticky report,
    result callback (`Conflict` or `Deploy`), optional Webex.
- **Writes back:** `Deploy` events without a promotion id (the hub creates the entry-hop promotion
  and its junction row), `POST /cdo/merge-status`.
- **Permissions:** `contents: write`, `pull-requests: write`, `issues: write`, `statuses: write`.

### `sf-promotion` — story-level promotion (the hub's queue dispatches this)

- **Inputs:** `promotion_id`, `work_items` (comma-separated keys, required), `feature_refs`
  (comma-separated; blank = feature prefix + each key), `target_env` (required), `test_level`
  (blank = configured), `specified_tests`, `check_only` (`true` = validate only, never merge),
  `allow_destructive` (default `true`).
- **Jobs:** `plan` (`plan.py target`; **refuses production**) → `promote` in the target's
  environment: callback `Running` (`Validation` when check-only), cut
  `promotion/<keys joined by +>-to-<env>` from the target and merge only the named feature refs,
  deploy `delta(target_sha_at_cut..HEAD)`, merge after success (skipped when check-only),
  merge-status, report (job summary), result callback, optional Webex.
- **Writes back:** promotion-scoped `Deploy` / `Validation` / `Conflict` events → promotion status,
  junction rows, work item stage, environment health, next queued promotion dispatched.
- **Permissions:** `contents: write`, `pull-requests: write`, `statuses: write`.

### `sf-promote` — whole-branch promotion (bulk path)

- **Inputs (dispatch):** `target_env` (required; not the entry, not production), `test_level`,
  `check_only`, `promotion_id`. **(call):** also `source_branch` and `label`.
- **Jobs:** `plan`: without `source_branch`, `plan.py promote <env>` resolves the previous
  environment's branch as the source (and refuses the entry environment); with `source_branch`,
  `plan.py target <env>`. `promote`: cut from the target, merge the source branch, deploy unless
  everything was already contained (`no_op`), merge after success, summary, callback.
- **Permissions:** `contents: write`, `pull-requests: write`, `statuses: write`.

### `sf-prod-release` — validate → required reviewer → quick deploy → merge → tag → release

- **Inputs:** `release_id`, `release_name` (blank = `<UTC date>-<run number>`), `source_ref` (blank =
  the last environment branch; the hub passes `release/<name>`), `test_level`, `specified_tests`,
  `allow_destructive`.
- **Jobs:**
  - `plan`: names the release and its label `release-<name>`.
  - `validate` (environment `production.validate_environment`, no reviewers): resolves the source
    SHA, callback `Release Running`, cuts `promotion/release-<name>-to-<prod>` from the production
    branch with the source merged, **validates** against production (`is_production`, canary for
    deletion-only or no-Apex deploys), uploads `release-manifest`, callback (still `Running` while
    waiting for the reviewer, or `Failed`). Outputs the validated deploy id, the cut SHA, the source
    SHA and the tree hash.
  - `deploy` (environment `production.deploy_environment`, **required reviewer**; only when the
    validation succeeded): rebuilds the tree from the recorded SHAs and **fails unless its tree hash
    equals the validated one**, quick-deploys the validated id, merges into the production branch
    (refused if it moved), tags `release-<name>` (annotated), publishes a GitHub Release with the
    manifest, callback `Release Success` (or `QuickDeploy Failed`; the GitHub Release URL travels in
    `pullRequestUrl`, from which the hub takes `Release_URL__c` and `Tag__c`), optional Webex.
- **Permissions:** `contents: write`, `pull-requests: write`, `statuses: write`.

### `assemble-release` — build `release/<name>`

- **Inputs (dispatch):** `release_id`, `release_name` (required), `work_items` (required). On
  schedule it queries the hub for releases in status `Assembling` (nothing to do without a hub).
- **Job:** for each release, check out `release/<name>` from the production branch, merge each
  work item's feature branch (`Feature_Branch__c`, else feature prefix + key); a missing branch or a
  conflict fails that release; success force-pushes the release branch (release branches are not
  environment branches). One `Release` callback per release, with the branch and conflict paths.
- **Permissions:** `contents: write`.

### `auto-merge-approved` — sweep green promotion PRs

- **Inputs:** `target_env` (blank = all).
- **Job:** reads `CDO_Project__c.Auto_Merge__c` for this repository from the hub (on when there is
  no hub). For each open PR whose head starts with the promotion prefix and carries a successful
  `sfdevops/deploy` status: if its base moved (`BEHIND` / `DIRTY`) comment and skip; otherwise merge
  pinned to the head (`--match-head-commit`). Normal promotions merge themselves; this only catches
  PRs left open (status registered late, merge timed out).
- **Permissions:** `contents: write`, `pull-requests: write`, `statuses: read`.

### `sf-conflict-check` — overlap report

- **Inputs:** `work_items` (limit the hub notifications; blank = all).
- **Job:** runs only for pushes to feature branches (plus schedule and dispatch). Reads in-flight
  `CDO_Component__c` rows from the hub (work items not Done or Cancelled), runs
  `conflict-check.py --git --hub-json`, writes the report to the job summary, and sends one
  `Conflict` callback per affected work item (status `Success`; the overlapping components get
  `Has_Conflict__c`).
- **Permissions:** `contents: read`.

### `sf-data-deploy` — records, not metadata

- **Inputs:** `data_set_id`, `source_env` and `target_env` (pipeline keys: environments, production
  or source orgs; must differ), `plan` (base64 JSON, [CONTRACTS.md §5](CONTRACTS.md)).
- **Jobs:** `plan` resolves both GitHub Environments (`plan.py target`, else `plan.py source`) and
  validates the plan (`data_plan.py steps`) → `export` in the source environment (`sf data export
  bulk` per template) → `import` in the target environment (`sf data upsert bulk` by external id,
  parents first) → callback `Data` (with the data set id as `deploymentId`, so the hub updates the
  data set's status). A production target runs in its reviewer-gated environment.
- **Permissions:** `contents: read`.

### `sf-ops-rollback`

- **Inputs:** `target_env` (required; production allowed, in its reviewer-gated environment), `sha`
  (required), `test_level`, `reason` (required).
- **Job:** cut `promotion/rollback-<sha10>-to-<env>` from the environment branch, replace
  `source_path` with its content at `sha` (warns when `sha` is not an ancestor), commit
  "Rollback <env> to <sha>", deploy that delta with deletions and `--ignore-warnings`, merge after
  success, callback `Rollback`.
- **Permissions:** `contents: write`, `pull-requests: write`, `statuses: write`.

### `sf-ops-redeploy-feature`

- **Inputs:** `work_item` (required), `work_item_id`, `target_env` (required, not production),
  `feature_ref`. Calls `sf-promotion` with `secrets: inherit`.

### `sf-ops-recreate-feature`

- **Inputs:** `work_item` (required), `work_item_id`, `feature_branch`, `paths` (newline or comma
  separated; blank = every path the old branch changed under `source_path` since its merge-base
  with the baseline).
- **Job:** pushes the old head to `backup/<branch>-<UTC timestamp>`, rebuilds the branch from the
  baseline carrying only those paths, force-pushes with lease (feature branches are not
  environment branches), callback `Commit` with the components.
- **Permissions:** `contents: write`.

### `sync-env-branches` — back-promotion

- **Inputs:** `target_env` (blank = every environment), `deploy` (`true` = deploy then merge; `false`
  = validate and report only; merging without deploying would break deploy-then-merge).
- **Jobs:** `plan` builds the list from `auto_json` → `sync` matrix calls `sf-promote` with
  `source_branch` = the baseline and label `sync-<baseline>`. Environment branches are merged,
  never reset.

### `sf-auth-check`

Authenticates to every source org, every chain environment and production's validate environment
(matrix from the config), prints `id`, `instanceUrl`, `apiVersion`, `connectedStatus`, and checks
the hub. It skips the production deploy environment, which would wait for its reviewer.
`contents: read`.

### `ci-selftest`

No org, no secrets. `unit`: installs the CLI and sfdx-git-delta, runs
`python3 -m unittest discover -s sf-pipeline/tests -v` and every `sf-pipeline/tests/test_*.sh`
(including the promotion simulation and the real-plugin delta test). `lint`: actionlint 1.7.12.
`matrix-plan` / `matrix-three` / `matrix-five`: the same matrix expands to 3 and 5 environments from
`tests/fixtures/config-3env.yml` and `config-5env.yml`. `contents: read`.

---

## Composite actions

### `sf-pipeline/deploy` — SF Deploy (one org)

Step order: setup-node → `install-sf.sh` → `auth-jwt.sh <environment>` → `delta.sh` (skipped for a
quick deploy) → `profiles.py` (when profiles or permission sets are in the delta) → test resolution
→ `manifest_to_md.py` → `deploy.sh` → `deploy_report.py` → result.

Test resolution, in order: (1) bypass → `NoTestRun`, or the production canary when Apex is involved;
(2) explicit `specified_tests`; (3) a configured level other than `RunSpecifiedTests` (production
refuses `NoTestRun` with Apex); (4) Apex changed → `specified_tests.py`, and when nothing resolves:
fail a check-only run, refuse production, `NoTestRun` with a warning elsewhere; (5) no Apex changed →
the production canary (or `RunLocalTests` when deleting Apex without a canary), otherwise
`NoTestRun`.

Deploy mode: `quick_deploy_id` → quick deploy; `check_only` → validate; coverage gate on (gate
enabled, no bypass, Apex in the delta) with `RunSpecifiedTests` → **validate, gate, then quick-deploy
the validated id**; otherwise `sf project deploy start --ignore-conflicts`.

| Input | Default | Meaning |
| --- | --- | --- |
| `environment` | required | Org alias and logical name |
| `ref` | required | The checked-out ref (recorded only) |
| `check_only` | `false` | Validate only |
| `quick_deploy_id` | `""` | Quick-deploy this validated id |
| `test_level` | `RunSpecifiedTests` | Requested level |
| `manifest_title` | `Deployment` | Manifest heading |
| `baseline_branch` | required | Delta base when `delta_from` is blank (`origin/<baseline_branch>`) |
| `delta_from` | `""` | Exact ref to diff from; promotions pass `target_sha_at_cut` |
| `source_path` | `force-app` | Metadata root |
| `api_version` | `66.0` | Package API version |
| `node_version` | `22` | Node for the CLI |
| `coverage_gate` | `false` | Enforce `coverage_threshold` when Apex changed |
| `coverage_threshold` | `85` | Minimum aggregate coverage |
| `profiles_mode` | `full` | `full` or `incremental` |
| `bypass` | `false` | Admin bypass (the workflow verifies the labeller first) |
| `is_production` | `false` | Apex with no covering test is refused |
| `destructive_test_names` | `""` | Production canary |
| `specified_tests` | `""` | Explicit tests |
| `allow_destructive` | `true` | Apply `destructiveChanges.xml` |
| `force_ignore` | `true` | Honour `.forceignore` in the delta |
| `ignore_warnings` | `false` | `--ignore-warnings` |
| `wait_minutes` | `90` | How long to wait for the org |
| `sf_consumer_key`, `sf_username`, `sf_instance_url`, `sf_jwt_key` | `""` | JWT sign-in |
| `sf_auth_url` | `""` | SFDX auth URL sign-in |

| Output | Meaning |
| --- | --- |
| `deploy_id` | The deploy job id |
| `validated_id` | The check-only id, when one ran |
| `outcome` | `success`, `failure` or `no_changes` |
| `has_changes`, `has_apex`, `has_js`, `has_lwc`, `has_destructive` | What the delta holds |
| `coverage_percent`, `coverage_note` | Aggregate coverage, or why it is blank |
| `tests_passed`, `failing_methods` | Test results (`Class.method: message` per line) |
| `test_level_used`, `tests_used` | What actually ran |
| `component_count`, `manifest_md`, `changed_files_file` | Package size, manifest path, changed paths |

The result step fails the job on any outcome other than `success` / `no_changes`.

### `sf-pipeline/promote` — promotion branch

| Input | Default | Meaning |
| --- | --- | --- |
| `mode` | required | `cut` or `merge` |
| `target_branch`, `target_env`, `work_item` | required | Target and the branch name parts |
| `feature_refs` | `""` | `cut`: comma-separated branches or SHAs to merge |
| `promotion_prefix` | `promotion/` | From the config |
| `target_sha_at_cut` | `""` | `merge`: the cut SHA |
| `deployed_sha` | `""` | `merge`: must equal HEAD |
| `merge_mode` | `auto` | `auto` (push, then PR), `push`, `pr` |
| `token` | `github.token` | PR fallback, commit status, comments (`GH_PAT || github.token` in workflows) |
| `pr_number` | `""` | `cut`: PR to comment conflicting paths on |

| Output | Meaning |
| --- | --- |
| `promotion_branch`, `target_sha_at_cut`, `head_sha`, `head_tree` | The cut |
| `merged_refs`, `no_op` | What was merged; true when everything was already in the target |
| `conflict`, `conflict_paths` | Conflict result |
| `merged`, `merge_sha`, `merge_method` (`push` / `pr` / `none`), `reason`, `pr_url` | Merge result |
| `exit_code` | 0 ok, 10 conflict, 11 target moved, 12 merge failed |

A non-zero exit fails the step with a specific error.

### `sf-pipeline/quality` — quality gates

| Input | Default | Meaning |
| --- | --- | --- |
| `has_apex`, `has_js` | required | From the delta |
| `has_lwc` | `false` | From the delta |
| `changed_files_file` | required | Changed paths (deletions excluded) |
| `source_path` | `force-app` | Sonar sources |
| `gate_pmd`, `gate_sonar`, `gate_jest` | `true` | From the config |
| `pmd_version` | `7.28.0` | PMD release downloaded from GitHub |
| `pmd_fail_priority` | `2` | Priority at or below this blocks |
| `node_version` | `22` | For Jest |
| `sonar_token`, `sonar_host_url` | `""` | Blank = Sonar skipped with a warning |
| `sonar_project_key` | `""` | Default `<owner>_<repo>` |
| `advisory` | `false` | Report but never fail (bypass) |

Outputs: `pmd_status`, `pmd_violations`, `jest_status`, `sonar_status`, `findings_file`
(`findings.json`, the hub's `CDO_Scan_Finding__c` payload). PMD scans only the changed Apex files;
Jest runs `sfdx-lwc-jest --findRelatedTests` on the changed LWC JS when the repository has a
`package.json` with `@salesforce/sfdx-lwc-jest`; Sonar runs `sonarqube-scan-action` and then
`sonar-gate.sh` waits for that analysis's quality gate.

### `sf-pipeline/report` — report

Inputs: `kind` (`validation` / `deploy` / `promotion` / `release`), `environment`, `title`, `outcome`,
`manifest_md` (`manifest.md`), `deploy_id`, `coverage_percent`, `coverage_note`, `tests_passed`,
`test_level`, `tests`, `failing_methods`, `head_sha`, `extra_md`, `pr_number` (blank = summary only),
`token`. Writes the job summary and, with a PR number, creates or updates one comment per
`kind:environment`, identified by `<!-- sfdevops:report:<kind>:<env> -->`. The second marker
`<!-- sfdevops:<kind> sha=… outcome=… coverage=… tests_passed=… -->` is what `sf-pr-approved` reads.

---

## Scripts

All under `sf-pipeline/scripts/`. Bash scripts use `set -euo pipefail`, never print a secret, and
write step outputs to `$GITHUB_OUTPUT` when it is set (otherwise they print `key=value`).

### Configuration and setup (run locally)

| Script | Interface | What it does |
| --- | --- | --- |
| `plan.py` | `plan.py [--config PATH] outputs \| resolve <branch> \| promote <env> \| target <env> \| source <name>` (or `PIPELINE_CONFIG`) | Config → outputs. `resolve`: the environment a PR into the branch validates against (`r_found`, `r_name`, `r_gh_environment`, `r_test_level`, `r_is_entry`, `r_is_prod`; a PR into production resolves to the validate environment). `promote`: manual target and its source branch (refuses the entry). `target`: one environment incl. `r_is_entry`, `r_prev`, `r_next`, `r_order`. Exit 2 invalid config, 3 unknown environment. Installs PyYAML with pip if missing |
| `onboard-org.sh` | `onboard-org.sh <alias> [ref]`; env `SOURCE_PATH`, `WAIT_MINUTES` (60) | Full deploy of `source_path` (optionally after a detached checkout of `ref`) with every test class in the tree, then a test run to populate `ApexCodeCoverage` |
| `bootstrap_secrets.py` (`bootstrap-secrets.sh` wrapper) | `--dry-run`, `--jwt --consumer-keys keys.json`, `--no-gh-pat`, `--generate-jwt-cert`, `--skip-token`, `--skip-environments`, `--reviewer <login>`, `--repo owner/name` | GitHub Environments (production deploy environment with a required reviewer), per-org secrets, hub repository secrets, the hub's External Credential token (hidden prompt), optionally `GH_PAT`. Secrets travel over stdin, never argv; nothing is printed |
| `seed-pipeline.py` | `--org <alias>`, `--check`, `--dry-run`, `--no-schedule` | Upserts `CDO_Project__c`, `CDO_Environment__c`, `CDO_Stage__c` on `Key__c` from the YAML; sets `CDO_Settings__c` org defaults; schedules the reconciler every 15 minutes; `--check` exits 1 on drift |
| `grant-app-access.sh` | `grant-app-access.sh <alias> <group> [username...]` | Assigns a permission set group (default: the CLI user), waiting for the group to finish recalculating |
| `setup-branch-protection.sh` | `[--dry-run] [--repo owner/name]` | Creates missing environment branches from the baseline, protects `protected_branches`; warns when the default branch is not the baseline |

### Pipeline steps (run by workflows)

| Script | Interface | What it does |
| --- | --- | --- |
| `install-sf.sh` | env `SF_CLI_VERSION` (2.153.5), `SGD_VERSION` (6.45.1) | Installs the pinned CLI and sfdx-git-delta; disables CLI auto-update and telemetry |
| `auth-jwt.sh` | `auth-jwt.sh <alias>`; env `SF_CONSUMER_KEY`, `SF_USERNAME`, `SF_JWT_KEY`, `SF_INSTANCE_URL`, `SF_AUTH_URL` | JWT when the three JWT secrets are set, else the auth URL; sets the default org; the key or URL lives in a `mktemp` file (umask 077) removed by a trap |
| `auth-hub.sh` | env `HUB_*`, `HUB_CALLBACK_STRICT` | Same for the hub under alias `hub` (never the default org); exits 0 with a notice when no hub secret is set; output `hub_available` |
| `delta.sh` | env `DELTA_FROM` (default `origin/$BASELINE_BRANCH`), `DELTA_TO` (`HEAD`), `DELTA_OUTPUT` (`.sgd`), `SOURCE_PATH`, `FORCE_IGNORE`, `SF_API_VERSION` | `sf sgd source delta` scoped to `source_path`; `FORCE_IGNORE=false` blanks `.forceignore` for the run. Outputs `has_changes`, `has_destructive`, `has_apex`, `has_apex_destructive`, `has_lwc`, `has_aura`, `has_js`, `has_profiles`, counts, manifest paths, `changed_files_file` |
| `profiles.py` | `--package PKG --source-path DIR --mode full\|incremental [--dry-run]` | `incremental` strips each profile / permission set to entries referencing components also in the package, keeping profile-level settings |
| `specified_tests.py` | `--package PKG --source-path DIR [--org ALIAS] [--coverage-json FILE] [--explicit "A,B"] [--cap 25] [--destructive XML]` | The three-pass resolver; outputs `apex_changed`, `tests`, `test_level` (empty when nothing resolved; never `RunLocalTests`), `unresolved`, `report` |
| `deploy.sh` | env `ALIAS`, `MODE` (`validate`/`deploy`/`quick`), `PACKAGE_XML`, `DESTRUCTIVE_XML`, `TEST_LEVEL`, `TESTS`, `QUICK_ID`, `WAIT_MINUTES`, `IGNORE_WARNINGS`, `OUT_JSON` | Starts the operation `--async`, waits, then writes `sf project deploy report --json` for the id; outputs `deploy_id`, `started` |
| `deploy_report.py` | `--report-json FILE [--threshold 85] [--coverage-gate] [--apex-changed] [--classes "A,B"] [--summary-file FILE]` | Decides the outcome from `result.status`, never the exit code; coverage from `codeCoverage` restricted to the changed classes; outputs `outcome`, `deploy_id`, `coverage_percent`, `tests_passed`, `failing_methods`, `component_failures`, `coverage_note`, `coverage_ok` |
| `manifest_to_md.py` | `--package PKG [--destructive XML] [--title T] [--out FILE]` | Markdown manifest (type, count, members; deletions separately) |
| `promote.sh` | `promote.sh cut\|merge`; env as in the promote action, plus `CUT_SHA`, `REMOTE`, `STATUS_CONTEXT` (`sfdevops/deploy`), `DELETE_PROMOTION_BRANCH` (true) | The promotion algorithm; exit 10 conflict, 11 target moved, 12 merge failed |
| `gate.sh` | `role <login>`, `is-admin <login>`, `labeler <pr> <label>`, `drop-label <pr> <label> <message>` | Repository permission checks through the collaborators API, at run time |
| `commit_helper.py` | `package --components <json\|@file> --denylist FILE --api VER --out package.xml`; `apply-deletes --deletes FILE --source-path DIR`; `payload --from REF --to REF --source-path DIR --out FILE` | The commit workflow's manifest, deletions and hub component payload |
| `sf_paths.py` | library | Source path → `(type, member)` and Unique ID `Type:Member` |
| `list-source-members.sh` | `list-source-members.sh <alias> [out]`; env `SOURCE_MEMBER_LIMIT` (2000) | `SourceMember` rows newest first: `type`, `name`, `lastModifiedDate`, `lastModifiedBy`, `state` |
| `conflict-check.py` | `[--git] [--hub-json FILE] [--baseline origin/main] [--feature-prefix feature/] [--source-path force-app]` | Overlaps on Unique ID; outputs `overlap_count`, `report`, `overlaps_json`; always exit 0 for overlaps |
| `data_plan.py` | `steps --plan-b64 B64 --out steps.json` | Orders data templates parents-first and builds the export SOQL with external-id relationship columns |
| `sonar-gate.sh` | env `SONAR_TOKEN`, `SONAR_HOST_URL`, `SONAR_PROJECT_KEY`, `SONAR_TIMEOUT` (300), `SONAR_POLL_INTERVAL` (5), `SONAR_REPORT_TASK` | Waits for the analysis and its quality gate; skips without credentials |
| `webex-notify.sh` | `webex-notify.sh "<markdown>"`; env `NOTIFY_WEBEX`, `WEBEX_WEBHOOK_URL` or `WEBEX_BOT_TOKEN` + `WEBEX_ROOM_ID` | Never fails the job |
| `ghout.py` | `ghout.py <file> <key>` | Reads one value from a `$GITHUB_OUTPUT`-format file |

### Hub callbacks

| Script | Interface | What it does |
| --- | --- | --- |
| `hub-notify.sh` | `hub-notify.sh deploy-callback\|merge-status deploy\|merge` | What the workflows call: skip without hub secrets, authenticate, build the payload with `hub_payload.py` from environment variables, POST |
| `hub_payload.py` | `hub_payload.py deploy\|merge` | Builds a `CallbackRequest` or merge-status body from env vars (`WORK_ITEM`, `EVENT_TYPE`, `STATUS`, `RUN_URL`, `COVERAGE_PERCENT`, …; `COMPONENTS_JSON_FILE`, `FINDINGS_JSON_FILE` embed arrays); empty values are omitted |
| `hub-callback.sh` | `hub-callback.sh deploy-callback\|merge-status\|source-members <json-file>`; env `HUB_CALLBACK_STRICT`, `HUB_CALLBACK_RETRIES` (3), `HUB_CALLBACK_BACKOFF` (2), `HUB_ALIAS` (`hub`) | POSTs to `<instance>/services/apexrest/cdo/<endpoint>` with the hub session's token (masked, sent from a private header file), retrying 5xx and connection errors; a failure is a warning unless strict |
| `hub-workitem-callback.sh` | env as `hub_payload.py`, `CALLBACK_OUT` | A standalone work-item-scoped callback (no promotion id); not used by the workflows today |

### Utilities not wired into the workflows

`audit.py` / `audit-append.sh` append one JSON line per event to a local audit file
(`$AUDIT_FILE`, default `.sgd/audit.jsonl`). `story-manifest.sh <work-item> [feature-branch]` writes a
work item's own manifest (`merge-base(baseline, feature)..feature`) to `.sgd-story/<WI>/`. Both are
tested and available for custom steps; the hub's `CDO_Audit_Event__c` is the audit trail of record.

### Tests

`sf-pipeline/tests/`: Python `test_*.py` (unittest), bash `test_*.sh`, `helpers.sh`,
`sfp_testutil.py`, fixtures. `bash sf-pipeline/tests/run_tests.sh` runs everything. See
[CONTRIBUTING.md](../CONTRIBUTING.md).

---

## Config reference

`sf-pipeline/pipeline.config.yml`. Defaults are applied by `plan.py`.

| Key | Default | Meaning |
| --- | --- | --- |
| `source_path` | `force-app` | Metadata root; every delta is scoped to it |
| `api_version` | `"66.0"` | Package API version |
| `node_version` | `"22"` | Node for the CLI and Jest |
| `baseline_branch` | `production.branch` | Feature branches are cut from it; the delta base in `baseline` mode; the hub's workflow ref |
| `delta_baseline` | `target` | `target` (promotion branch from the target) or `baseline` (PR validation diffs against the baseline) |
| `branch_prefixes.feature` | `feature/` | Feature branch prefix; the work item key follows it |
| `branch_prefixes.promotion` | `promotion/` | Promotion branch prefix |
| `source_orgs[].name` | required | Key used by the hub and `sf-commit` / `sf-list-changes` |
| `source_orgs[].gh_environment` | `name` | GitHub Environment holding the org's secrets |
| `source_orgs[].org_alias` | `""` | Local CLI alias (setup scripts only) |
| `source_orgs[].description` | `""` | Free text |
| `environments[]` | required, at least one | The chain, in order; the first is the entry |
| `environments[].name`, `.branch` | required | Unique name and branch |
| `environments[].gh_environment` | `name` | GitHub Environment |
| `environments[].org_alias` | `""` | Local CLI alias |
| `environments[].test_level` | `RunSpecifiedTests` | Default level for deploys to it |
| `production.name` | `prod` | Logical name (hub and logs); must not collide with an environment |
| `production.branch` | required | Production branch; must not be an environment branch |
| `production.deploy_environment` | `name` | GitHub Environment **with** required reviewers |
| `production.validate_environment` | `<deploy_environment>-validate` | GitHub Environment **without** reviewers; must differ |
| `production.org_alias` | `""` | Local CLI alias |
| `production.release_branch_prefix` | `release/` | Release branches |
| `production.test_level` | `RunSpecifiedTests` | Production test level |
| `production.destructive_tests` | `""` | Canary test(s) for deletion-only or no-Apex production deploys |
| `hub.org_alias` | `""` | Hub alias for the setup scripts; empty = GitHub-only |
| `hub.project_key` | repository name | `CDO_Project__c.Key__c` (read by `seed-pipeline.py` only) |
| `quality_gates.pmd` / `.sonar` / `.apex_coverage` / `.jest` | `true` | Gate switches |
| `coverage_threshold` | `85` | 0–100 |
| `profiles_mode` | `full` | `full` or `incremental` |
| `approved_label` | `approved` | Self-service approval label |
| `bypass_label` | `bypass-quality-gates` | Admin-only bypass label |
| `notifications.webex` | `false` | Webex notifications |

`plan.py outputs` emits every setting plus `env_count`, `env_names`, `env_branches`, `entry_name`,
`entry_branch`, `entry_gh_environment`, `last_name`, `last_branch`, `prod_name`, `prod_branch`,
`prod_deploy_environment`, `prod_validate_environment`, `prod_test_level`, `release_branch_prefix`,
`destructive_tests`, `auto_json` (the chain, for matrices), `chain_json` (chain plus production),
`source_orgs_json`, `protected_branches` (production first, then the chain in reverse).

---

## Secrets reference

### Per GitHub Environment

One environment per source org, per chain environment, plus `production.validate_environment` and
`production.deploy_environment` (both hold the production org's credentials).

| Secret | Mode | Content |
| --- | --- | --- |
| `SF_AUTH_URL` | auth URL (default) | `force://<clientId>:<secret>:<refreshToken>@<instance>` |
| `SF_CONSUMER_KEY` | JWT | Connected App / External Client App consumer key |
| `SF_JWT_KEY` | JWT | base64 of `server.key`, one line |
| `SF_USERNAME` | both | Integration username |
| `SF_INSTANCE_URL` | both | Login or My Domain URL (JWT default `https://login.salesforce.com`) |

JWT is used whenever `SF_CONSUMER_KEY`, `SF_USERNAME` and `SF_JWT_KEY` are all set.

### Repository

| Secret | Needed for |
| --- | --- |
| `HUB_AUTH_URL`, or `HUB_CONSUMER_KEY` + `HUB_JWT_KEY` (+ `HUB_USERNAME`, `HUB_INSTANCE_URL`) | Callbacks and hub queries; absent = GitHub-only mode |
| `GH_PAT` | PRs that trigger workflows, pushes, PR-path merges (falls back to `GITHUB_TOKEN`) |
| `SONAR_TOKEN`, `SONAR_HOST_URL` | SonarQube gate (skipped with a warning when absent) |
| `WEBEX_WEBHOOK_URL`, or `WEBEX_BOT_TOKEN` + `WEBEX_ROOM_ID` | Webex notifications (`notifications.webex: true`) |

### Hub

The GitHub token lives in the External Credential `GitHub_API_Credential`, principal `GitHub_PAT`,
parameter `Token` (set by `bootstrap_secrets.py` through the API, or by hand in Setup). The Named
Credential `GitHub_API` sends `Authorization: Bearer <Token>`. Users can make the callout only with
a permission set granting the principal (`CDO_Developer`, `CDO_Release_Manager`,
`CDO_Pipeline_Admin`). No secret lives in metadata.

### What never leaves the runner

Keys and auth URLs are written to private temp files and removed by traps; the hub access token is
masked with `::add-mask::` and sent from a header file; no script echoes a secret. Fork PRs receive
no secrets (validation is skipped). See [SECURITY.md](../SECURITY.md).

---

## Concurrency model

| Group | Used by | Behaviour |
| --- | --- | --- |
| `sf-deploy-<environment branch>` | `sf-int-deploy`, `sf-promotion`, `sf-promote`, `sf-ops-rollback` (job level, `cancel-in-progress: false`) | One deploy per environment at a time |
| `sf-prod-release` | `sf-prod-release` (workflow level) | One production release at a time. A production rollback uses `sf-deploy-<production branch>`, a different group |
| `sf-pr-validation-<PR>` | `sf-pr-validation` (`cancel-in-progress: true`) | A new push cancels the older validation |
| `sf-commit-<feature branch>` | `sf-commit` | Commits to one feature branch in order |
| `assemble-release`, `sf-conflict-check` | those workflows | Single runs (the conflict check cancels the older run) |

**A concurrency group is not a queue.** GitHub keeps one run executing and one pending; a third
arrival evicts the pending one. Two simultaneous approvals on the entry stage can therefore lose the
middle one. The real queue is in the hub: `CDOPromotionDispatcher` allows one promotion in flight
(`Dispatched` / `Deploying`) per target stage, dispatches the oldest `Queued` promotion first, and
locks the stage row while deciding. When a promotion finishes (callback or reconciler), the next one
is dispatched. Cost: a promotion can wait behind another rather than fail fast.

**Salesforce serialises deploys per org.** Validations are not in the deploy group, so a validation
and a deploy can be queued at the same org; Salesforce runs one after the other, and from the
Salesforce side it can look like a duplicate deployment.

---

## Adding an environment

No workflow changes. For example, to add `uat` between `qa` and `stage`:

1. **Config:** insert the entry in chain order:

   ```yaml
     - name: uat
       branch: uat
       gh_environment: uat
       org_alias: acme-uat
   ```

   Land it on the baseline and carry it to the environment branches (see
   [Updating pipeline files on protected branches](#updating-pipeline-files-on-protected-branches)).
2. **Org:** `sf org login web --alias acme-uat ...`, then
   `bash sf-pipeline/scripts/onboard-org.sh acme-uat`.
3. **GitHub Environment and secrets:** re-run `bootstrap_secrets.py` (it creates `uat` and its
   secrets, and refreshes the others).
4. **Branch:** `bash sf-pipeline/scripts/setup-branch-protection.sh` creates `uat` from the
   baseline and protects it.
5. **Hub:** `py sf-pipeline/scripts/seed-pipeline.py`, then `--check`.
6. **Prove it:** run `sf-auth-check`.

To remove an environment, delete it from the config and re-seed; `seed-pipeline.py --check` reports
hub stages that no longer exist in the YAML (it does not delete them; deactivate or delete them in
the hub). Merge or promote its in-flight work first.

## Adding a source org

Add a `source_orgs` entry (`name`, `gh_environment`, `org_alias`), log in, re-run
`bootstrap_secrets.py` and `seed-pipeline.py`. Developers then pick it as the work item's source org.
No onboarding deploy is needed (nothing deploys to a source org), though a source-tracked org is
needed for the change list.

---

## Updating pipeline files on protected branches

After `setup-branch-protection.sh`, the production branch and every environment branch require the
`sfdevops/deploy` status, which only a deployed promotion carries, and admins are enforced on every
branch except the entry. Pipeline files must still reach every environment branch, because
`pull_request_review` workflows run from the PR's base branch.

**1. Land the change on the baseline** (here also the production branch). Pick one:

- *Lift protection briefly* (simplest, recorded in the repository's audit log):

  ```bash
  gh api -X DELETE repos/<owner>/<repo>/branches/main/protection
  git push origin main
  bash sf-pipeline/scripts/setup-branch-protection.sh      # re-applies every rule
  ```

- *Through a reviewed PR*: open a PR into `main`, review it, then as an admin set the status on its
  head and merge (an explicit, visible override for a change with no org payload):

  ```bash
  gh api repos/<owner>/<repo>/statuses/<head sha> -f state=success -f context=sfdevops/deploy \
    -f description="Pipeline-only change; no org deploy"
  gh pr merge <n> --merge --match-head-commit <head sha>
  ```

**2. Carry it to the environment branches.**

- *With in-flight work on the environment branches:* run `sync-env-branches` (deploy `true`). Each
  environment gets a normal promotion that merges the baseline into it; a pipeline-only change has no
  metadata delta (`no_changes`), so it merges after an empty deploy. Anything else on the baseline
  that the environment lacks (a production hotfix) deploys with it. **Evidence: pending live run.**
- *Before any work is in flight* (fresh setup): remove protection from the environment branches,
  delete them, and re-run `setup-branch-protection.sh`, which recreates them from the baseline.
  Never do this once environments hold unreleased work: environment branches are merged, never
  reset.

---

## Observability

| Where | What |
| --- | --- |
| Job summaries | The manifest, the test resolver's report (how each test was found), the deploy summary, PMD findings, merge results, overlap reports |
| PR comments | One sticky comment per environment and kind, plus conflict, hold and label-removal comments |
| Run names | Every workflow's `run-name` carries the work item key and the promotion or release id (`Promote WI-0001 → qa · <promotion id>`), which the reconciler uses to find a run whose callback never arrived |
| Commit statuses | `sfdevops/deploy` on each deployed promotion head that merged through a PR |
| Releases and tags | `release-<name>` tags and GitHub Releases with the manifest |
| Hub records | `CDO_Deployment__c` (one per attempt, de-duplicated), work item and promotion status, environment health, `CDO_Scan_Finding__c`, `CDO_Approval__c` |
| Hub audit trail | `CDO_Audit_Event__c`: one per callback and per hub action (`PromotionDispatched`, `PromotionQueueHeld`, `Approval`, `Release`, …); append-only |
| Hub dashboards | **Pipeline** (stages, work items, in-flight promotions, latest deployment per environment), **Delivery Metrics** (weekly DORA-style metrics), **Governance** (approvals waiting, audit log, operations, GitHub connection test) |
| Reconciler | `CDO_PromotionReconciler`, scheduled every 15 minutes by `seed-pipeline.py`; run once with `CDO_PromotionReconciler.sweepNow()` in anonymous Apex |

**Callback failures** are warnings in the log (`hub callback '<endpoint>' returned HTTP <code>`),
never failed deploys, unless a workflow step sets `HUB_CALLBACK_STRICT=true`.

---

## Pinned versions

| Tool | Version | Where |
| --- | --- | --- |
| Salesforce CLI | 2.153.5 | `install-sf.sh` (`SF_CLI_VERSION`) |
| sfdx-git-delta | 6.45.1 | `install-sf.sh` (`SGD_VERSION`) |
| PMD | 7.28.0 | `quality/action.yml` (`pmd_version`) |
| Java | Temurin 21 | `quality/action.yml` |
| Node | `node_version` from the config (22) | every job that installs the CLI |
| actionlint | 1.7.12 | `ci-selftest.yml` |
| Actions | `actions/checkout@v7`, `actions/setup-node@v7`, `actions/setup-java@v6`, `actions/upload-artifact@v7`, `actions/download-artifact@v8`, `SonarSource/sonarqube-scan-action@v8` | workflows and actions |
