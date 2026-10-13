# End-to-end runbook (live phase)

Run after the maintainer has run `bootstrap_secrets.py` (all org and hub secrets in place) and
`sf-auth-check` is green. Each scenario names the spec §16 acceptance item it proves. Record the
run URL and the decisive log lines for each in `docs/build-log/session-2.md` and
`docs/ACCEPTANCE.md`.

Work items below are created in the hub first (so callbacks have a record to land on), then the
branches are made locally with the maintainer identity, or through `sf-commit` from `sfp-dev`.

| # | Scenario | How | Expected evidence | §16 item |
|---|---|---|---|---|
| 0 | Auth everywhere | dispatch `sf-auth-check` | 5 org jobs + hub job green | setup |
| 1 | One-field change | `feature/WI-0001`: add `Invoice__c.Notes__c`; PR → `int` | `sf-pr-validation`: manifest with 1 CustomField (plus the permission set if edited); check-only deploy green; sticky PR comment | PR runs delta → PMD/Sonar → check-only + manifest comment |
| 2 | One-class change runs only its tests | `feature/WI-0002`: edit `InvoiceService` | resolver picks `InvoiceServiceTest` (naming) + coverage-map tests; never `RunLocalTests` | one-class change runs only its tests |
| 3 | Coverage-map pass | `feature/WI-0003`: edit `InvoiceTotals` | resolver finds `BillingScenarioTests` via ApexCodeCoverage (name does not match) | resolver pass 1 |
| 4 | No covering test | `feature/WI-0004`: add `UncoveredUtil` with no test | validation fails with "No Apex test covers UncoveredUtil" | class with no test fails validation |
| 5 | Coverage below threshold | `feature/WI-0005`: class with a partial test (~50 %) | validation fails the 85 % gate | coverage below threshold fails |
| 6 | Bypass label | admin adds `bypass-quality-gates` to WI-0005's PR, re-runs validation | tests/coverage skipped with the admin warning; label re-verified via the permission API | bypass works only for an admin |
| 7 | Non-admin `approved` on entry | needs a second (non-admin) GitHub account; otherwise proven by the gate logic in `sf-int-deploy` ctx + gate.sh | label removed + comment; `proceed=false` | developer cannot self-approve entry |
| 8 | Admin approval starts the entry hop | admin adds `approved` to WI-0002's PR | `sf-pr-approved` records the approval → calls `sf-int-deploy` → promotion branch cut → deploy → merge; PR shows as merged | approval automatically starts the entry promotion; deploy-then-merge |
| 9 | Story-level promotion int → qa | from the hub (Promote & Deploy) or dispatch `sf-promotion` for WI-0002 → qa | promotion branch `promotion/WI-0002-to-qa`, delta vs qa, merge after success; hub promotion Deployed, junction row Deployed | every hop cuts/merges/deploys/merges after success; junction rows |
| 10 | Drift test | land a qa-only edit to `InvoiceService` on `qa` (via a promotion of WI-0006), then promote WI-0002's edit to the same file into qa | qa org afterwards contains both edits (query the class body) | no clobber |
| 11 | Conflict | WI-0007 edits the same line as WI-0006 on qa | promotion aborts, comments paths, fails; hub WI Blocked + Conflict_Paths__c | conflicting promotion aborts, comments, fails, blocks |
| 12 | Target moved mid-run | start a promotion to qa, push another promotion's merge to qa before the merge step | merge refused (exit 11), org deployed but branch untouched, merge-status callback with the reason | merge refuses when the target moved |
| 13 | Running→Success leaves one row | inspect `CDO_Deployment__c` for scenario 9's run URL | exactly one row | one deployment row, not two |
| 14 | Prod release | dispatch `sf-prod-release` (source = stage) | validate job in prod-validate; deploy job waits for the reviewer (screenshot/API shows pending); approve; quick deploy of the validated id; tree-identity check; merge; tag; GitHub Release | prod validates, waits, quick-deploys validated id, merges, tags, releases |
| 15 | Destructive-only to prod with the canary | delete a class through the chain, release | prod deploy runs `PipelineCanaryTest` only | destructive-only change deploys with the canary |
| 16 | Incremental profiles | `profiles_mode: incremental` on a branch; edit Invoice_User + one field | stripped to in-delta entries, userPermissions kept (unit-tested; live optional) | incremental profile shaping |
| 17 | 3 → 5 environments | `ci-selftest` matrix jobs | 3 and 5 matrix legs from the same workflow | config-only scaling |
| 18 | Hub UI | open the app in the browser pane | App Launcher shows SF DevOps; every tab opens; pipeline home renders stages | app visible, every tab opens |
| 19 | Hub dispatch → callback | from a work item: Validate / Commit | `GitHubService` 204; run; callback; audit event | integration contracts end to end |
