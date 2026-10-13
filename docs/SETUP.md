# Setup

This guide takes you from nothing to a validated pull request, then to the full pipeline with the
Salesforce hub app. Follow it top to bottom. Every command is copy-paste ready; replace the example
aliases (`acme-int` and so on) with your own.

- **Fastest path to a first validated PR (target: under 30 minutes):** steps 1–4, then 8–13,
  skipping the hub steps 5–7. That is [GitHub-only mode](#github-only-mode-no-hub). Add the hub
  later by running steps 5–7 and re-running step 10.
- **Full setup with the hub:** every step in order. Plan for roughly 15–20 minutes more.

These times are targets; a full timed run by a new adopter is **Evidence: pending live run**.

Windows users: run the bash commands in **Git Bash**, and run Python as `py` (see
[python3 on Windows](#python3-on-windows-is-the-microsoft-store-stub)). macOS and Linux users: run
Python as `python3`. Where a command shows `py`, use `python3` on macOS/Linux.

---

## What you will end up with

| Thing | Where |
| --- | --- |
| A GitHub repository holding the pipeline and your metadata | `main` = baseline and production branch; `int`, `qa`, `stage` = environment branches |
| One GitHub Environment per org, with that org's sign-in secrets | `dev`, `int`, `qa`, `stage`, `prod-validate`, `prod` (required reviewer) |
| Branch protection that only the pipeline can satisfy | every environment branch and `main` require the `sfdevops/deploy` status |
| A hub org running the SF DevOps app (optional) | records, UI, the promotion queue, the audit trail |

---

## Prerequisites

### Accounts and orgs

- A **GitHub account with admin rights** on the repository you will create. Required reviewers on a
  GitHub Environment are free on public repositories; on private repositories they need a paid
  GitHub plan.
- **One Salesforce org per pipeline environment** (for example int, qa, stage sandboxes), the
  **production org**, and at least one **developer org** to commit from. For the commit screen's
  change list, the developer org needs source tracking (scratch orgs have it; for Developer and
  Developer Pro sandboxes, enable "Enable Source Tracking in Developer and Developer Pro
  Sandboxes" in your production org's Dev Hub settings).
- **A hub org** for the SF DevOps app (optional; recommended to keep it separate from production).
  Any org that allows Apex, custom objects and Named Credentials works: a Developer Edition org, or
  a scratch org for a trial.
- A **user in each org** that the pipeline acts as. With the default sign-in mode (SFDX auth URL)
  the workflows act as the user you log in with in step 3, so use a dedicated integration user with
  the System Administrator profile (or an equivalent permission set) if you can.

### Tools on your machine

| Tool | Version | Check |
| --- | --- | --- |
| git | 2.40+ | `git --version` |
| GitHub CLI | 2.40+, logged in as a repository admin with `repo` and `workflow` scopes | `gh auth status` |
| Salesforce CLI | 2.x (the runners pin 2.153.5) | `sf --version` |
| Node.js | 22 (the CLI and LWC Jest) | `node --version` |
| Python | 3.10+ with PyYAML (`py -m pip install pyyaml`, or `python3 -m pip install pyyaml`) | `py --version` / `python3 --version` |
| bash | Git Bash on Windows; any bash on macOS/Linux | `bash --version` |
| OpenSSL | only for JWT mode | `openssl version` |

If `gh auth status` does not show the `workflow` scope, run
`gh auth refresh -h github.com -s repo,workflow`.

---

## Step 1 — Create your repository

On <https://github.com/muraliseelam/sfdevops-app>, click **Use this template → Create a new
repository** (or fork it). Then clone your copy:

```bash
gh repo create <you>/<your-repo> --template muraliseelam/sfdevops-app --public --clone
cd <your-repo>
```

You do not need the hub app's branch (`platform/sfdevops-app`) in your repository: step 5 deploys
the hub from a clone of the upstream repository. (If you want it, choose "Include all branches"
when you create from the template.)

The repository ships a small sample app in `force-app/` (an `Invoice__c` object, Apex with tests,
a trigger, an LWC with a Jest test, a permission set and `PipelineCanaryTest`). Keep it for a trial.
For a real project, replace `force-app/` on `main` with your **production** metadata (retrieved
from production, so the baseline describes production), and keep a stable, always-passing test
class to name in `production.destructive_tests`.

## Step 2 — Edit `sf-pipeline/pipeline.config.yml`

This is the only file a project edits. Its comments are the contract. Change these parts:

```yaml
source_path: force-app          # where your metadata lives
api_version: "66.0"             # Metadata API version for the delta package
baseline_branch: main           # production baseline; feature branches are cut from it
delta_baseline: target          # keep "target" (the Copado model)

source_orgs:                    # developer orgs you commit FROM
  - name: dev                   # the key the hub and workflows use
    gh_environment: dev         # GitHub Environment holding this org's secrets
    org_alias: acme-dev         # your local sf CLI alias (setup scripts only)

environments:                   # the promotion chain, in order; the FIRST is the entry
  - name: int
    branch: int
    gh_environment: int
    org_alias: acme-int
    test_level: RunSpecifiedTests
  - name: qa
    branch: qa
    gh_environment: qa
    org_alias: acme-qa
  - name: stage
    branch: stage
    gh_environment: stage
    org_alias: acme-stage

production:
  name: prod
  branch: main                          # the branch that represents production
  deploy_environment: prod              # GitHub Environment WITH a required reviewer
  validate_environment: prod-validate   # GitHub Environment WITHOUT reviewers
  org_alias: acme-prod
  release_branch_prefix: "release/"
  test_level: RunSpecifiedTests
  destructive_tests: "PipelineCanaryTest"   # a stable test class that exists in force-app

hub:
  org_alias: acme-hub           # delete this block (or leave org_alias empty) for GitHub-only mode

quality_gates: { pmd: true, sonar: true, apex_coverage: true, jest: true }
coverage_threshold: 85
profiles_mode: full
approved_label: approved
bypass_label: bypass-quality-gates
notifications: { webex: false }
```

Rules `plan.py` enforces: environment names and branches are unique; the production branch is not
also an environment branch; `deploy_environment` and `validate_environment` differ; test levels are
`NoTestRun`, `RunSpecifiedTests`, `RunLocalTests` or `RunAllTestsInOrg`. You can use 3, 4 or 5
environments; nothing else changes. Every key is described in
[DEVOPS.md → Config reference](DEVOPS.md#config-reference).

Check the file:

```bash
py sf-pipeline/scripts/plan.py outputs        # macOS/Linux: python3 sf-pipeline/scripts/plan.py outputs
```

It prints `env_count`, `env_names`, `entry_branch`, `prod_branch`, `protected_branches` and the
rest. Exit code 2 with an `::error title=pipeline.config.yml::` line names the problem.

Commit and push the change to `main` now. Protection comes last, in step 13.

```bash
git add sf-pipeline/pipeline.config.yml force-app
git commit -m "Configure the pipeline for our orgs"
git push origin main
```

## Step 3 — Log in to every org with the Salesforce CLI

Use exactly the `org_alias` values from the config.

```bash
# sandboxes (or use your My Domain URL, e.g. https://acme--int.sandbox.my.salesforce.com)
sf org login web --alias acme-dev   --instance-url https://test.salesforce.com
sf org login web --alias acme-int   --instance-url https://test.salesforce.com
sf org login web --alias acme-qa    --instance-url https://test.salesforce.com
sf org login web --alias acme-stage --instance-url https://test.salesforce.com
# production and the hub
sf org login web --alias acme-prod  --instance-url https://login.salesforce.com
sf org login web --alias acme-hub   --instance-url https://login.salesforce.com
sf org list
```

Log in as the user the pipeline should act as: in the default sign-in mode, step 10 turns each of
these CLI logins into the CI credential.

**Trying it with scratch orgs** (this is how the reference setup runs; scratch orgs live at most 30
days):

```bash
sf org create scratch --edition developer --alias sfp-int --duration-days 30 --target-dev-hub <devhub-alias>
```

Scratch orgs created this way are already logged in. If your Dev Hub itself was authorized with
JWT, its scratch orgs carry no refresh token and cannot provide an auth URL; log in to the Dev Hub
with `sf org login web` first.

## Step 4 — Bring each org to the baseline

The pipeline's invariant is "an environment branch describes its org". A new org starts empty, so
deploy the baseline into it once. `onboard-org.sh` deploys `source_path` in full with every test
class in the tree, then runs those tests once more so the org's coverage map (`ApexCodeCoverage`)
exists for the test resolver.

```bash
bash sf-pipeline/scripts/onboard-org.sh acme-int
bash sf-pipeline/scripts/onboard-org.sh acme-qa
bash sf-pipeline/scripts/onboard-org.sh acme-stage
bash sf-pipeline/scripts/onboard-org.sh acme-dev
```

Each run prints `deploy id: ... status: Succeeded components: N tests: n/n` and ends with
`Org <alias> now matches the current checkout under force-app.` A failure prints each component or
test failure; fix it and run again (the script is safe to re-run).

**Production:** `onboard-org.sh acme-prod` deploys the baseline in full to production and runs
every test class. Do it only when `main` really is your production metadata (a trial org, or a
baseline you just retrieved from production). Otherwise skip production here.

## Step 5 — Install the hub app (skip for GitHub-only mode)

Two ways. Pick one.

**A. Install the package (one command).** The hub is published as the unlocked package
`SF DevOps` (no namespace). Version `0.1.0-2` is `04thm000002tWm5AAE` (94 % Apex coverage). It is
a beta version: it installs into sandboxes, Developer Edition and scratch orgs; a production org
needs a released (promoted) version, which this page will list when there is one.

```bash
sf package install --package 04thm000002tWm5AAE --target-org acme-hub --wait 30 --no-prompt
```

**B. Deploy from source.** Clone the app's branch next to your repository and run the deploy
script, which deploys in the only order that works (a layout cannot reference a quick action
created in the same deploy; permission sets reference the classes, app and tabs), checks every
step by its deploy id, and pauses the hub's scheduled reconciler around a redeploy (scheduled
Apex otherwise blocks redeploying the classes it references):

```bash
cd ..
git clone --branch platform/sfdevops-app --single-branch https://github.com/muraliseelam/sfdevops-app.git sfdevops-hub
cd sfdevops-hub
bash tools/deploy-hub.sh acme-hub --tests
cd ../<your-repo>
```

`--tests` runs the hub's five test classes during the Apex step (130 test methods). The individual
`sf project deploy start` commands and the reasons for the order are in the app branch's
`tools/README.md`.

## Step 6 — Grant access to the app

Run from your pipeline repository. Assign `CDO_Admin_Access` to yourself (the CLI user of the hub
alias). That user is also the **callback integration user** in the default sign-in mode, and needs
at least `CDO_Pipeline_Admin_Access`: it grants the REST resources and the field-level security on
every hub field (a field deployed without a permission set is invisible even to a System
Administrator).

```bash
bash sf-pipeline/scripts/grant-app-access.sh acme-hub CDO_Admin_Access
bash sf-pipeline/scripts/grant-app-access.sh acme-hub CDO_Developer_Access dev1@acme.com dev2@acme.com
bash sf-pipeline/scripts/grant-app-access.sh acme-hub CDO_Release_Manager_Access lead@acme.com
```

The script waits for a freshly deployed group to finish recalculating, and leaves existing
assignments alone. Groups: `CDO_Developer_Access`, `CDO_Release_Manager_Access`,
`CDO_Pipeline_Admin_Access`, `CDO_Admin_Access` (see
[PRODUCT-DESIGN.md → Roles](PRODUCT-DESIGN.md#roles)).

## Step 7 — Seed the hub's pipeline records from the YAML

The hub keeps a mirror of the chain (`CDO_Project__c`, `CDO_Environment__c`, `CDO_Stage__c`). It is
never edited by hand: `seed-pipeline.py` generates it from the config.

```bash
py sf-pipeline/scripts/seed-pipeline.py --dry-run     # print the records
py sf-pipeline/scripts/seed-pipeline.py               # upsert them into hub.org_alias
py sf-pipeline/scripts/seed-pipeline.py --check       # exit 1 if the hub drifted from the YAML
```

It upserts on external ids (safe to re-run), sets the `CDO_Settings__c` org defaults (GitHub owner
and repository from your `origin` remote, workflow ref = the baseline, default project key), and
schedules the promotion reconciler every 15 minutes (`--no-schedule` skips that). Run it from your
own clone, so `origin` points at your repository. Re-run it whenever you change the config.

## Step 8 — Create the GitHub token

The hub starts workflows with this token, and the pipeline can use it as `GH_PAT`.

On GitHub: **Settings → Developer settings → Personal access tokens → Fine-grained tokens →
Generate new token**.

- Resource owner: the repository owner. Repository access: **Only select repositories** → your
  repository.
- Repository permissions:

| Permission | Access | Used for |
| --- | --- | --- |
| Actions | Read and write | the hub's `workflow_dispatch`; the reconciler reads runs |
| Contents | Read and write | pushes to feature, promotion and environment branches |
| Pull requests | Read and write | opening and merging PRs |
| Metadata | Read | required by GitHub |
| Workflows | Read and write | pushing commits that touch `.github/workflows` |
| Commit statuses | Read and write | when the token is also the `GH_PAT` secret: the protected-branch merge sets `sfdevops/deploy` with it |

Copy the token. You paste it once, in step 10, into a hidden prompt.

**Why `GH_PAT` matters:** a PR opened with the default `GITHUB_TOKEN` does not trigger workflows.
With `GH_PAT`, `sf-open-pr` opens PRs that trigger `sf-pr-validation` normally; without it,
`sf-open-pr` dispatches the validation explicitly and warns.

## Step 9 — Repository settings

In your repository: **Settings → Actions → General → Workflow permissions** → tick **Allow GitHub
Actions to create and approve pull requests**. Without `GH_PAT`, `sf-open-pr` and the
protected-branch merge path open PRs with `GITHUB_TOKEN`, which needs this setting. The workflows
declare their own least-privilege `permissions:`, so the default token permission can stay
read-only.

## Step 10 — Store every credential with `bootstrap_secrets.py`

Run it yourself, once, with every org logged in (step 3) and `gh` logged in as a repository admin.
It never prints a secret value.

```bash
py sf-pipeline/scripts/bootstrap_secrets.py --dry-run          # Windows
python3 sf-pipeline/scripts/bootstrap_secrets.py --dry-run     # macOS / Linux
```

The dry run shows the repository, the production reviewer (you, unless `--reviewer <login>`), the
environments it would create and the secret names it would set. Then run it for real:

```bash
py sf-pipeline/scripts/bootstrap_secrets.py                    # macOS/Linux: python3 ...
```

What it does:

1. Creates the GitHub Environments: each source org's, each chain environment's,
   `prod-validate`, and `prod` **with you as the required reviewer** (self-review allowed, so a
   single maintainer can approve).
2. For each org, sets that GitHub Environment's secrets. Production's org goes into both
   production environments.
3. Sets the hub's repository secrets (when `hub.org_alias` is set).
4. Asks once, with hidden input, for the token from step 8, and stores it in the hub's Named
   Credential (External Credential `GitHub_API_Credential`, principal `GitHub_PAT`, parameter
   `Token`), and as the `GH_PAT` repository secret (`--no-gh-pat` skips that). Without a hub it
   still offers to store `GH_PAT`. Press Enter to skip.

Other options: `--skip-token`, `--no-gh-pat`, `--skip-environments`, `--reviewer <login>`,
`--repo owner/name`, and `--generate-jwt-cert` (create the JWT key pair before `--jwt`).

### Choose a sign-in mode

**SFDX auth URL (default).** Each secret `SF_AUTH_URL` (and `HUB_AUTH_URL` for the hub) is the
auth URL of your CLI login: `force://<clientId>:<secret>:<refreshToken>@<instance>`. It works in
every org, including orgs where Salesforce no longer lets you create a Connected App. Trade-off:
it is a refresh token from a CLI login. The workflows act as that user, and anyone who obtains
the secret can use the org until the token is revoked (in Setup, **Connected Apps OAuth Usage →
Salesforce CLI**, or on the user's record under **OAuth Connected Apps**). It is the simplest
mode.

**JWT (`--jwt`).** Each org needs a Connected App or an External Client App holding your
certificate, and the secrets are `SF_CONSUMER_KEY` + `SF_JWT_KEY` (the base64 private key). No
refresh token is stored; the trade-off is one app per org to create and maintain. See
[sf-pipeline/connected-app/README.md](../sf-pipeline/connected-app/README.md) for both app types.

```bash
# 1. the key pair (bootstrap reuses it if it exists)
mkdir -p ~/.sfdevops
MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout ~/.sfdevops/server.key -out ~/.sfdevops/server.crt -subj "/CN=sfdevops-ci"
# 2. upload ~/.sfdevops/server.crt to an app in every org (and the hub), collect the consumer keys:
#    keys.json = {"acme-dev": "3MVG...", "acme-int": "3MVG...", ..., "acme-hub": "3MVG..."}
# 3. store everything
py sf-pipeline/scripts/bootstrap_secrets.py --jwt --consumer-keys keys.json
```

Keep `keys.json` and `~/.sfdevops/` out of the repository (`.gitignore` already ignores `*.key`,
`*.pem` and `.sfdevops/`).

### The secrets it sets

| Where | Auth URL mode | JWT mode |
| --- | --- | --- |
| Each GitHub Environment | `SF_AUTH_URL`, `SF_USERNAME`, `SF_INSTANCE_URL` | `SF_CONSUMER_KEY`, `SF_JWT_KEY`, `SF_USERNAME`, `SF_INSTANCE_URL` |
| Repository (hub) | `HUB_AUTH_URL`, `HUB_USERNAME`, `HUB_INSTANCE_URL` | `HUB_CONSUMER_KEY`, `HUB_JWT_KEY`, `HUB_USERNAME`, `HUB_INSTANCE_URL` |
| Repository | `GH_PAT` (unless `--no-gh-pat`) | same |
| Hub org | External Credential token | same |

The sign-in scripts use JWT whenever the consumer key, username and key are all present, and the
auth URL otherwise. Optional repository secrets you add yourself: `SONAR_TOKEN` + `SONAR_HOST_URL`
(SonarQube), `WEBEX_WEBHOOK_URL` or `WEBEX_BOT_TOKEN` + `WEBEX_ROOM_ID` (Webex, with
`notifications.webex: true`).

`bootstrap_secrets.py` end to end against GitHub is **Evidence: pending live run** (its dry run is
verified). If a step fails, see [Troubleshooting](#troubleshooting).

## Step 11 — Prove every org signs in: `sf-auth-check`

```bash
gh workflow run sf-auth-check.yml
gh run watch "$(gh run list --workflow sf-auth-check.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

It authenticates to every source org, every chain environment and `prod-validate`, prints
`sf org display` (id, instance URL, API version, connected status — no tokens), and checks the hub.
It does not touch the `prod` environment, which would wait for a reviewer. Every matrix job must
be green before you continue.

## Step 12 — The default branch must be the baseline

Scheduled workflows (`assemble-release`, `sf-conflict-check`) run only on the default branch, and the
hub dispatches workflows on the ref in `CDO_Settings__c.Workflow_Ref__c` (the baseline, set by
step 7). With the reference config the baseline is `main`, already the default. If you changed
`baseline_branch`:

```bash
gh api -X PATCH repos/<owner>/<repo> -f default_branch=<baseline>
```

## Step 13 — Create and protect the environment branches (run LAST)

Run this only after your last pipeline change has landed on the baseline. It creates every missing
environment branch from the baseline (so the pipeline files exist on every branch, which
`pull_request_review` workflows need) and protects the production branch and every environment
branch:

- require a pull request (0 approvals: review happens on feature PRs), dismiss stale reviews;
- require the `sfdevops/deploy` commit status with "branches up to date" (strict), so a promotion
  whose target moved can never merge and a feature PR's merge button never works;
- block force pushes and deletions;
- enforce for admins on every branch except the entry environment's.

```bash
bash sf-pipeline/scripts/setup-branch-protection.sh --dry-run
bash sf-pipeline/scripts/setup-branch-protection.sh
```

Expected: `created stage from main ...`, `created qa ...`, `created int ...`, then
`protected main (enforce_admins=true)` … `protected int (enforce_admins=false)`.

After this, changing pipeline files means following
[DEVOPS.md → Updating pipeline files on protected branches](DEVOPS.md#updating-pipeline-files-on-protected-branches).

## Step 14 — Your first change, end to end

### With the hub

1. **Make a change in the developer org**: for example add a field to `Invoice__c`, or edit the
   `invoiceSummary` LWC.
2. In the hub: **App Launcher → SF DevOps → Pipeline**. Use **New work item**: Subject, Project,
   Source org `dev`. Open the new work item (`WI-0001`).
3. In **Commit changes**, pick the source org and click **List changes** (runs `sf-list-changes`).
   When the list arrives, select your components, write a message and click **Commit** (runs
   `sf-commit`). The work item becomes **Committed**; the commit and its components appear on the
   record; branch `feature/WI-0001` exists in GitHub.
4. Click **Open pull request** (runs `sf-open-pr`). The work item becomes **In Review** and links
   the PR into `int`.
5. `sf-pr-validation` runs on the PR: delta, quality gates for what changed, check-only deploy to
   `int`. The PR gets a comment **Validation against `int`** with outcome, tests, coverage and the
   component manifest; the work item shows the validation status and coverage.
6. Approve: another person approves the PR, or (single maintainer) you add the `approved` label as
   a repository admin. `sf-pr-approved` records the approval and starts `sf-int-deploy`: it deploys
   to `int` and merges. The PR gets **Deployed to `int` and merged** and shows as merged; the work
   item's current stage is `int`.
7. On the work item, click **Promote & Deploy** to send it to `qa` (runs `sf-promotion`), then to
   `stage`.
8. Production: **Release Board** → create a release, add the work item, **Assemble**, then
   **Release to Production**. Approve the `prod` environment in GitHub when the validation passes.

### GitHub-only

```bash
git switch -c feature/WI-0001 origin/main
# change files under force-app/ (e.g. retrieve from your dev org with sf project retrieve start)
git add force-app && git commit -m "[WI-0001] Add Invoice__c.Notes__c"
git push -u origin feature/WI-0001
gh pr create --base int --head feature/WI-0001 --title "[WI-0001] Add a notes field" \
  --body "Specified-Tests: InvoiceServiceTest"
```

Watch the validation comment, then approve (review or admin `approved` label). Promote onward:

```bash
gh workflow run sf-promotion.yml -f work_items=WI-0001 -f target_env=qa
```

### You are done when

- [ ] `sf-auth-check` is green for every org (and the hub).
- [ ] A PR into the entry branch got a **Validation** comment with a component manifest.
- [ ] Approval deployed it to the entry org and the PR shows as merged.
- [ ] (Hub) The work item shows its commits, deployments, approval and current stage, and the
      **Audit Events** tab lists each step.
- [ ] `py sf-pipeline/scripts/seed-pipeline.py --check` prints `hub matches pipeline.config.yml`.

---

## Troubleshooting

### `sf-auth-check` fails: "SF_AUTH_URL does not look like an SFDX auth URL"

The secret does not start with `force://`. Current sf CLI versions redact secrets in
`sf org display --json`; `bootstrap_secrets.py` therefore reads `sf org auth show-sfdx-auth-url`.
If you set a secret by hand, do the same, without printing it:

```bash
sf org auth show-sfdx-auth-url --target-org acme-int --no-prompt --json \
  | py -c "import json,sys; print(json.load(sys.stdin)['result']['sfdxAuthUrl'])" \
  | gh secret set SF_AUTH_URL --env int
```

(Use `gh secret set HUB_AUTH_URL` without `--env` for the hub.)

### "SFDX auth URL login failed" / the refresh token was revoked

Log in again (`sf org login web --alias <alias> ...`) and re-run `bootstrap_secrets.py` (or the
command above). Auth URLs die when the user's session is revoked, the password policy forces it, or
the org (scratch org) expires.

### "the CLI login for '<alias>' has no refresh token to share"

The alias was logged in with JWT, or is a scratch org of a JWT-authorized Dev Hub. Log in with
`sf org login web`, or use `--jwt`.

### JWT login fails

Check that the app holds the certificate matching `SF_JWT_KEY`, that the integration user's profile
or permission set is pre-authorized on the app ("Admin approved users are pre-authorized"), that
`SF_INSTANCE_URL` is the right login URL (`https://test.salesforce.com` or the My Domain URL for a
sandbox), and that `SF_JWT_KEY` is the base64 of `server.key` on one line (the key, not the
certificate).

### You switched from JWT to auth URL, but JWT is still used

JWT wins whenever `SF_CONSUMER_KEY`, `SF_USERNAME` and `SF_JWT_KEY` are all set. Delete the JWT
secrets: `gh secret delete SF_CONSUMER_KEY --env int` and `gh secret delete SF_JWT_KEY --env int`.

### "You can't create a connected app"

Salesforce blocks new Connected Apps in many orgs. Use the default auth URL mode, or an External
Client App for JWT ([connected-app README](../sf-pipeline/connected-app/README.md)).

### The hub token could not be stored

`bootstrap_secrets.py` prints `could not store the token through the API`. Set it by hand:
**Setup → Named Credentials → External Credentials → GitHub API Credential → Principals →
GitHub_PAT → Edit → Authentication Parameters → Token**. Then in the hub, **Pipeline → Governance →
Integration → Test GitHub connection**.

### Hub buttons are disabled: "GitHub is not configured"

`CDO_Settings__c` has no GitHub owner/repository: run `seed-pipeline.py` (step 7). "Workflow
dispatch is turned off" means `Dispatch_Enabled__c` is unchecked in **SF DevOps Settings**.

### The App Launcher does not show SF DevOps

App visibility is a separate grant: assign one of the permission set groups (step 6). A group
that was just deployed must finish recalculating; `grant-app-access.sh` waits for it.

### Hub callbacks fail, or records do not update

Look for `hub callback ... HTTP status` in the workflow log. A callback failure is a warning, not a
failed deploy. `HTTP 401`/`INVALID_SESSION_ID`: the `HUB_*` secrets are wrong or expired. `HTTP
403`/`404`: the integration user lacks `CDO_Pipeline_Admin_Access` (REST class access and field
security). No callback at all: the `HUB_*` secrets are missing (GitHub-only mode). Stuck
promotions are swept by the reconciler every 15 minutes.

### A PR opened from the hub never validates

Without `GH_PAT`, a PR opened with `GITHUB_TOKEN` does not trigger workflows; `sf-open-pr` then
dispatches `sf-pr-validation` itself (look for the warning in its log). Re-run validation from the
work item (**Validate**) or `gh workflow run sf-pr-validation.yml -f pr_number=<n>`.

### Approving did nothing

- The approval was held: the PR has a comment "Approval recorded, but the deploy ... is held". The
  head commit's validation had not reported, failed, or measured coverage below the threshold. Fix
  it, wait for a green validation, and approve again (submit another approving review, or remove and
  re-add the label).
- A non-admin added `approved` on the entry stage: the label was removed with a comment. Ask a
  reviewer to approve the PR.

### The validation fails with "No covering test"

The changed Apex has no test the resolver can find. Add a test class (for example `FooTest`), or
name one in the PR body: `Specified-Tests: FooTest`. See the
[user guide](PIPELINE-USER-GUIDE.md#naming-tests).

### Tests fail with "No such column" on a field you just deployed

Deploying a field grants no field-level security, not even to the admin running tests. Run tests as
a user with the permission set (`System.runAs`), as the sample's `InvoiceTestData` does, and grant
the field in a permission set.

### The merge was refused: "target moved during the run"

Another promotion landed on the same branch while yours deployed. The org has your tree, but the
branch was not merged. Run the promotion again; it re-cuts from the new target head.

### The merge failed: "push ... rejected and no PR path is available"

Branch protection rejected the push and the PR fallback could not run. Without `GH_PAT`, tick
"Allow GitHub Actions to create and approve pull requests" (step 9). With `GH_PAT`, make sure the
token has Pull requests and Commit statuses write.

### A scheduled workflow never runs

Scheduled workflows run only from the default branch. Make the baseline the default branch
(step 12).

### `python3` on Windows is the Microsoft Store stub

`python3` may exist on `PATH` but open the Store instead of running. Use `py`. The bash scripts
probe `python3`, `python` and `py` and use the first that runs.

### `openssl ... -subj "/CN=..."` fails in Git Bash

Git Bash rewrites `/CN=...` into a Windows path. Prefix the command with `MSYS_NO_PATHCONV=1`.

### Bash scripts fail on the runner with `$'\r': command not found`

A script was committed with CRLF line endings. `.gitattributes` forces LF (`* text=auto eol=lf`);
renormalize with `git add --renormalize .` and commit.

### A metadata file fails to parse with an XML comment at the top

An XML comment before the root element breaks sfdx source parsing. Put comments inside the root
element.

### A deploy "failed" but the org has the change (or the reverse)

The CLI exit code is not the truth; the pipeline reads `sf project deploy report` for the deploy
id. Confirm the org, not the branch: check the component's `LastModifiedDate` in the org.

---

## Re-pointing from scratch orgs to sandboxes and production

The reference setup runs on scratch orgs `sfp-dev`, `sfp-int`, `sfp-qa`, `sfp-stage`, `sfp-prod` and
`sfp-hub`, which **expire on 2026-11-12**. After that every sign-in fails and `sf-auth-check` goes
red. To move to long-lived orgs (or to re-point any environment):

1. **Log in** to the new orgs under new aliases (step 3).
2. **Edit `pipeline.config.yml`**: change each `org_alias` (`sfp-int` → `acme-int`, …, `hub.org_alias`).
   Branch and environment names can stay. Commit to the baseline (see
   [updating pipeline files](DEVOPS.md#updating-pipeline-files-on-protected-branches) if protection
   is on).
3. **Bring each new org to its branch** with `onboard-org.sh`. For a brand-new pipeline every branch
   equals the baseline, so `bash sf-pipeline/scripts/onboard-org.sh acme-int` is enough. For an
   environment whose branch already holds work that is not in production, deploy **that branch** so
   the org matches it:

   ```bash
   git status                      # must be clean: the script checks out the ref (detached)
   bash sf-pipeline/scripts/onboard-org.sh acme-qa origin/qa
   git switch main
   ```

4. **Re-run `bootstrap_secrets.py`** (step 10). It overwrites each GitHub Environment's secrets with
   the new orgs' credentials. With `--skip-environments` it leaves the environments alone.
5. **If the hub moved**, deploy the hub app to the new hub org (step 5), grant access (step 6), and
   seed it (step 7); the `HUB_*` secrets and the token are refreshed by step 4.
6. **If only aliases changed**, still re-run `seed-pipeline.py` so `Org_Alias__c` in the hub
   matches, then `seed-pipeline.py --check`.
7. **Run `sf-auth-check`** (step 11).

For production, `onboard-org.sh` is only right when the baseline is a faithful copy of production
(see step 4).

---

## GitHub-only mode (no hub)

Everything in GitHub works without the hub. Leave out the `hub:` block (or leave `org_alias` empty)
and skip steps 5–7.

| Works the same | Differs |
| --- | --- |
| PR validation, PR comments, quality gates | No records, no Salesforce UI, no audit trail in Salesforce (job summaries and PR comments remain) |
| Approval by review or admin label → entry deploy + merge | No promotion queue: concurrent dispatches rely on the GitHub concurrency group, which is not a queue |
| `sf-promotion`, `sf-promote`, `sf-prod-release`, ops workflows, data deploy (dispatched by you) | You dispatch them with `gh workflow run` or the Actions tab |
| `sf-conflict-check` (git-only overlaps) | No `CDO_Component__c` overlap data; scheduled `assemble-release` does nothing (dispatch it with inputs) |
| `auto-merge-approved` (auto-merge on) | No `Auto_Merge__c` switch |

Every callback prints `Hub callback skipped ... running in GitHub-only mode` and exits 0.

**`GH_PAT` in GitHub-only mode.** `bootstrap_secrets.py` asks for the token only when a hub is
configured, so set `GH_PAT` yourself (the command prompts for the value without echoing it):

```bash
gh secret set GH_PAT
```

**Day-to-day commands:**

```bash
# validate a PR again
gh workflow run sf-pr-validation.yml -f pr_number=42
# promote work items into an environment (not production)
gh workflow run sf-promotion.yml -f work_items=WI-0001,WI-0002 -f target_env=qa
# whole-branch promotion from the previous environment
gh workflow run sf-promote.yml -f target_env=stage
# assemble a release branch, then release it
gh workflow run assemble-release.yml -f release_name=2026-10-20 -f work_items=WI-0001,WI-0002
gh workflow run sf-prod-release.yml -f release_name=2026-10-20 -f source_ref=release/2026-10-20
```

Name feature branches `feature/<KEY>` (the work item key is taken from the branch name, then from
the PR title, then `PR-<number>`).
