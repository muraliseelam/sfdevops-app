# sf-pipeline

Everything the GitHub Actions workflows in `.github/workflows/` run. Full reference:
[docs/DEVOPS.md](../docs/DEVOPS.md).

## The rule

**A project edits only `pipeline.config.yml`.** Environments, branches, GitHub Environments, test
levels, gates, the coverage threshold and labels all come from it, through `scripts/plan.py`.
Nothing else in this folder or in `.github/workflows/` names an environment, a branch or an org
count. If you find yourself editing a workflow or a script to fit your orgs, the change belongs in
the config (or the config is missing a key: open an issue).

After changing the config, also run `scripts/seed-pipeline.py` so the hub's copy (project, stages,
environments) matches, and see
[updating pipeline files on protected branches](../docs/DEVOPS.md#updating-pipeline-files-on-protected-branches).

## Map

| Path | What it is |
| --- | --- |
| `pipeline.config.yml` | The single source of truth. Its comments are the contract |
| `deploy/action.yml` | Composite action "SF Deploy (one org)": sign in, delta, profiles, test resolution, manifest, validate / deploy / quick deploy, report, coverage gate |
| `promote/action.yml` | Composite action: cut a promotion branch from the target and merge the feature (conflict gate); after a deploy, merge it into the target, pinned to the deployed commit and refused if the target moved |
| `quality/action.yml` | Composite action: PMD, LWC Jest, SonarQube, each only when its component type changed |
| `report/action.yml` | Composite action: job summary and one sticky PR comment per environment and kind |
| `config/pmd/ruleset.xml` | The Apex PMD ruleset (priority 1–2 block, 3+ advise) |
| `config/commit-denylist.txt` | Component types `sf-commit` never writes to git (credentials, org-wide settings) |
| `connected-app/` | Reference Connected App for JWT sign-in, and the External Client App and auth URL alternatives |
| `scripts/plan.py` | Config → workflow outputs (`outputs`, `resolve`, `promote`, `target`, `source`) |
| `scripts/delta.sh` | sfdx-git-delta, scoped to `source_path` |
| `scripts/promote.sh` | The promotion-branch algorithm (`cut`, `merge`) |
| `scripts/specified_tests.py` | Three-pass Apex test resolver |
| `scripts/profiles.py` | `full` / `incremental` profile and permission set shaping |
| `scripts/deploy.sh`, `scripts/deploy_report.py` | Start, wait, and judge a deploy by its id |
| `scripts/manifest_to_md.py` | package.xml → markdown manifest |
| `scripts/auth-jwt.sh`, `scripts/auth-hub.sh`, `scripts/lib.sh` | Sign-in (JWT or SFDX auth URL) and shared helpers |
| `scripts/hub-notify.sh`, `scripts/hub_payload.py`, `scripts/hub-callback.sh`, `scripts/hub-workitem-callback.sh` | Callbacks to the hub |
| `scripts/gate.sh` | Repository permission checks for the approval and bypass labels |
| `scripts/commit_helper.py`, `scripts/sf_paths.py`, `scripts/list-source-members.sh` | The commit screen and commit workflow |
| `scripts/conflict-check.py` | Overlap detection across in-flight work items |
| `scripts/data_plan.py` | Data-deploy plan → ordered export/upsert steps |
| `scripts/sonar-gate.sh`, `scripts/webex-notify.sh` | SonarQube gate, Webex notification |
| `scripts/install-sf.sh`, `scripts/ghout.py` | Pinned CLI install; read a value from a `$GITHUB_OUTPUT` file |
| `scripts/audit.py`, `scripts/audit-append.sh`, `scripts/story-manifest.sh` | Utilities (local JSON-lines audit, per-work-item manifest), not wired into the workflows |
| `scripts/onboard-org.sh` | Bring an org to the baseline (full deploy + tests + coverage map) |
| `scripts/bootstrap_secrets.py`, `scripts/bootstrap-secrets.sh` | GitHub Environments and every secret, in one run |
| `scripts/seed-pipeline.py` | Hub records from the YAML (`--check` for drift) |
| `scripts/grant-app-access.sh` | Assign the hub's permission set groups |
| `scripts/setup-branch-protection.sh` | Create and protect the environment branches (run last) |
| `tests/` | Python and bash tests, the pure-git promotion simulation, fixtures (including 3- and 5-environment configs). Run `bash sf-pipeline/tests/run_tests.sh` |

## Running the scripts locally

Run them from the repository root, in bash (Git Bash on Windows). Python scripts need Python 3.10+
and PyYAML; on Windows use `py`, elsewhere `python3`. Scripts that need an org use the aliases in
the config (`org_alias`).
