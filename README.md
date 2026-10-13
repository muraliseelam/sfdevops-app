# SF DevOps

An open-source delivery pipeline for Salesforce, comparable to Copado. **GitHub Actions** does the
work (delta, static analysis, validation, deployment, merge). A **Salesforce app** (SF DevOps, the
"hub") keeps the records and gives developers and release managers a UI, so they never need to open
GitHub. **One YAML file** configures everything.

License: [Apache-2.0](LICENSE). Repository: <https://github.com/muraliseelam/sfdevops-app>.

---

## Why it is built this way

- **Salesforce records.** Release managers, QA leads and auditors live in Salesforce, where reports,
  list views, approvals and sharing come free. Every commit, validation, approval, promotion,
  deployment and release becomes a record, and everything of consequence writes an append-only audit
  event.
- **Actions executes.** Salesforce cannot run PMD or SonarQube, compute an sfdx-git-delta package,
  hold git history or give you free compute. GitHub Actions can.
- **Git is the truth.** Each environment has a branch that describes its org. A branch is merged
  only **after** its org was deployed.

The two halves meet at exactly two contracts: the hub starts workflows with `workflow_dispatch`, and
workflows report back through Apex REST callbacks ([docs/CONTRACTS.md](docs/CONTRACTS.md)). The hub
is optional: without it the pipeline runs in GitHub-only mode.

## The 60-second tour

1. A developer creates work item **WI-0032** in the hub, clicks **List changes** to see what they
   changed in their developer org, selects the components and clicks **Commit**. A workflow
   retrieves exactly those components into `feature/WI-0032`, cut from production.
2. **Open pull request** opens a PR into the entry environment (`int`). The pipeline cuts a
   promotion branch from `int`, merges the feature into it, runs PMD / LWC Jest / SonarQube for what
   changed, and validates the delta against the `int` org with only the tests that cover the change.
   A PR comment shows the manifest, tests and coverage.
3. A reviewer approves. Approval **starts** the deploy to `int`; after it succeeds, the pipeline
   merges the promotion into `int`. If `int` moved during the run, the merge is refused rather than
   publishing a tree that was never deployed.
4. The developer clicks **Promote & Deploy** to move WI-0032 to `qa`, then `stage`. The hub queues
   promotions, one at a time per stage; each hop deploys the difference between *that* environment
   and the change, so nothing the target already had is overwritten.
5. A release manager assembles a release and clicks **Release to Production**. It validates against
   production, waits for the required reviewer, quick-deploys the validated payload, merges, tags and
   publishes a GitHub Release. The work items become **Done**.

## Features

- **Promotion branches, Copado-style:** every hop deploys `diff(target at cut .. target + feature)`,
  because Salesforce deploys whole files and a merge-base diff would silently revert the target's own
  changes. Proven by a pure-git simulation (27 assertions).
- **Deploy, then merge,** with the merge pinned to the deployed commit and refused if the target moved.
  Works under branch protection: the pipeline sets the `sfdevops/deploy` status and merges a
  promotion PR; feature PR merge buttons can never be used.
- **Tests from the delta:** the org's coverage map, then naming conventions, then changed test
  classes; never a silent whole-org run. A class with no covering test fails validation and is refused
  by production. `Specified-Tests: A, B` in a PR names tests explicitly.
- **Coverage gate without half-deploys:** deploys that change Apex validate first, gate on coverage,
  then quick-deploy the validated id.
- **Production release** in two GitHub Environments: validate without reviewers, then a required
  reviewer, a byte-identical rebuild check, quick deploy, merge, tag and GitHub Release.
- **Approvals:** native PR review, or an `approved` label that is admin-only on the entry stage and
  self-service later. An admin-only `bypass-quality-gates` label, re-verified at run time.
- **Quality gates** that fire only for what changed: PMD, LWC Jest, SonarQube; Sonar and Jest skip with
  a warning when not set up.
- **A real promotion queue** in Apex (a GitHub concurrency group is not a queue), plus a reconciler that
  recovers lost callbacks from GitHub.
- **Conflict pre-check** across in-flight work items, joined on component identity.
- **Ops:** rollback to a known-good commit, redeploy a feature, recreate a feature branch, sync
  environments after a release, records-not-metadata data deploys.
- **Config-only:** 3, 4 or 5 environments by editing `sf-pipeline/pipeline.config.yml`; no workflow
  names an environment, branch or org count.
- **Setup scripts:** onboard an org, store every credential (auth URL or JWT), seed the hub from the
  YAML, grant access, protect branches.

## Status

Verified: 100 Python unit tests, 8 bash test files (280 assertions), the promotion simulation (27
assertions), actionlint over every workflow, the 3-versus-5-environment matrix proof, and the sample
app onboarded to five orgs. End-to-end
runs against live orgs (validation, approvals, promotions, production release, callbacks) are
**pending a live run** with the maintainer's secrets. Details:
[PRODUCT-DESIGN.md → Verification status](docs/PRODUCT-DESIGN.md#13-verification-status).

## Quickstart

Full instructions: **[docs/SETUP.md](docs/SETUP.md)**.

1. **Use this template** (or fork) and clone your repository.
2. Edit **`sf-pipeline/pipeline.config.yml`**: your environments, branches, org aliases and
   production. Check it with `py sf-pipeline/scripts/plan.py outputs` (`python3` on macOS/Linux).
3. Log in to every org: `sf org login web --alias <alias> --instance-url <url>`.
4. Bring each org to the baseline: `bash sf-pipeline/scripts/onboard-org.sh <alias>`.
5. Optional hub: `sf package install --package 04thm000002tWm5AAE --target-org <hub>` (or
   `bash tools/deploy-hub.sh <hub>` from branch `platform/sfdevops-app`), then
   `bash sf-pipeline/scripts/grant-app-access.sh <hub> CDO_Admin_Access` and
   `py sf-pipeline/scripts/seed-pipeline.py`.
6. Create a fine-grained GitHub token, then store every credential:
   `py sf-pipeline/scripts/bootstrap_secrets.py`.
7. Prove every org signs in: `gh workflow run sf-auth-check.yml`.
8. Last: `bash sf-pipeline/scripts/setup-branch-protection.sh`. Then open your first PR.

## Repository layout

```text
.github/
  workflows/                17 pipeline workflows + sf-auth-check + ci-selftest
  ISSUE_TEMPLATE/, pull_request_template.md
sf-pipeline/
  pipeline.config.yml       THE config (the only file a project edits)
  deploy/ quality/ report/ promote/   composite actions
  scripts/                  plan.py, delta.sh, promote.sh, specified_tests.py, setup scripts, ...
  config/                   PMD ruleset, commit deny-list
  connected-app/            reference Connected App for JWT mode
  tests/                    unit tests, bash tests, promotion simulation, fixtures
force-app/                  business metadata (a small sample Invoicing app)
docs/                       design, setup, user guide, operator reference, contracts, diagrams
```

## Two branches, two halves

| Branch | Holds | Deployed to |
| --- | --- | --- |
| `main` (and the environment branches `int`, `qa`, `stage`) | The pipeline (`.github/`, `sf-pipeline/`) and your metadata (`force-app/`) | Your environment orgs and production |
| `platform/sfdevops-app` | The hub app: an sfdx project with package directory `sfdevops-app/` (22 objects, 31 Apex classes, 13 LWCs, 4 permission set groups) | The hub org only |

The hub app is kept off `main` (and git-ignored there) so it can never enter an environment's delta.
To work on both, check the hub branch out as a worktree: `git worktree add .platform/hub
platform/sfdevops-app` (`.platform/` is ignored on `main`).

## Documentation

| Document | For |
| --- | --- |
| [docs/SETUP.md](docs/SETUP.md) | Installing and configuring, troubleshooting, re-pointing orgs, GitHub-only mode |
| [docs/PIPELINE-USER-GUIDE.md](docs/PIPELINE-USER-GUIDE.md) | Developers and release managers: the life of a work item |
| [docs/DEVOPS.md](docs/DEVOPS.md) | Operators: every workflow, action, script, config key and secret |
| [docs/PRODUCT-DESIGN.md](docs/PRODUCT-DESIGN.md) | Architecture, decisions and their costs, spec deviations, traps |
| [docs/CONTRACTS.md](docs/CONTRACTS.md) | The hub ↔ pipeline contracts |
| [docs/diagrams/](docs/diagrams/README.md) | Architecture, branching and change-flow diagrams (draw.io) |
| [sf-pipeline/README.md](sf-pipeline/README.md) | The pipeline folder's map |
| [sf-pipeline/connected-app/README.md](sf-pipeline/connected-app/README.md) | Connected App, External Client App and auth URL sign-in |
| [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | Contributing, reporting vulnerabilities, conduct |

## License

Apache License 2.0. See [LICENSE](LICENSE).
