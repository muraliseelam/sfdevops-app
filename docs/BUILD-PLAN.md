# Build plan — Salesforce DevOps Delivery Platform

Source spec: the "master build prompt" (§0–§17), kept outside this repository. This file is the working plan. It holds the decisions and
the gates for each work session. Where it and the spec disagree, the decisions recorded here win.

Planned 2026-10-12. Session 1 is scheduled for **2026-10-13 04:30 Central (CDT, UTC−5)**,
unattended. Session 2 is **not scheduled yet**. See "Scheduled task status" in §6.

---

## 1. What is being built (one paragraph)

A Copado-equivalent release platform for Salesforce. **GitHub Actions** executes the work
(delta, PMD/Sonar, validate, deploy, merge). A **Salesforce hub org** holds the records and
the UI (`CDO_*` objects, 30 Apex classes, 13 LWCs). **One YAML file**
(`sf-pipeline/pipeline.config.yml`) is the only thing a project edits. The two sides talk over
exactly two contracts: an outbound `workflow_dispatch` (Apex → GitHub, expects 204, string
inputs only) and an inbound REST callback (`/services/apexrest/cdo/deploy-callback`). The core
algorithm cuts a promotion branch from the *target* env branch, merges the feature into it,
deploys `diff(target_sha_at_cut..HEAD)`, and merges into the target **only after** the deploy
succeeds and **only if** the target has not moved since the cut. This exists because Salesforce
deploys whole files, so a merge-base diff would silently clobber changes the target already has.

## 1b. Open-source goal (user, 2026-10-12)

This will be published as an open-source application. Anyone who installs the Salesforce app
must be able to set up the pipeline easily. Every phase is judged against that, not only
against "works for us".

- **Install the hub app with one command.** Build it as an **unlocked package with no namespace**
  from DevHub `partner-pbo`, so adopters run `sf package install`. Source deploy stays a
  documented fallback.
- **The GitHub side is a template.** Mark the repo as a GitHub template. An adopter clicks
  "Use this template", edits only `pipeline.config.yml`, and runs the scripts.
- **Every setup script is generic and config-driven.** `bootstrap-secrets.sh`,
  `seed-pipeline.py`, `setup-branch-protection.sh`, `onboard-org.sh` and `grant-app-access.sh`
  read org aliases, environments and branches from the config. No alias, username or repo name
  belonging to this project appears in any committed file except the example config and the docs.
- **Quickstart target:** from zero to the first validated PR in **under 30 minutes**,
  following `docs/SETUP.md` alone. The user's own morning run of `bootstrap-secrets.sh` is the
  first real test of this.
- **Optional integrations degrade gracefully.** Sonar, Webex and LWC Jest skip with a clear
  message when their secrets or tooling are absent, and never fail an adopter's first run.
- **Repo hygiene for OSS:** a README with a quickstart, `CONTRIBUTING.md`, `SECURITY.md`
  (how to report vulnerabilities, and the secrets model), issue and PR templates, and the
  existing Apache-2.0 `LICENSE`.

## 2. Facts found on this machine (2026-10-12 23:40 CDT)

| Item | Finding | Impact |
| --- | --- | --- |
| Repo | `muraliseelam/sfdevops-app`, **public**, default branch `main`, only `LICENSE` + `README.md` | Greenfield. Public repo, so GitHub Environment required reviewers are free. Workflow logs are public, so never log org data or secrets |
| Commit identity | History uses `murali.reddy60@gmail.com` | Every commit: `git -c user.name="Murali Seelam" -c user.email=murali.reddy60@gmail.com commit ...`, with no Claude attribution |
| git / gh | git 2.55, gh 2.102, logged in as `muraliseelam` (scopes: repo, workflow) | Can push, create environments and branch protection, open PRs, and run and watch workflows |
| Salesforce CLI | sf 2.153.5 (Node 24), plugin `code-analyzer 5.16` (PMD). `sfdx-git-delta` not installed locally | Delta runs on GitHub runners, which is where it runs in production anyway |
| Java / Node / OpenSSL | OpenJDK 21, Node 24, OpenSSL 3.5 | PMD, LWC Jest and cert generation all work locally |
| Python | **Not installed locally** | All Python verification runs on GitHub runners through a self-test workflow (decision D9). Nothing gets installed on this machine |
| Orgs | DevHub `partner-pbo` (11 of 20 active scratch slots free). Scratch orgs `sfp-dev`, `sfp-int`, `sfp-qa`, `sfp-stage`, `sfp-prod`: **empty** (0 custom classes, 0 custom objects), API 68.0, **expire 2026-11-12**. No other local project references them | Safe to use as the chain. Everything live stops working when they expire, so docs must explain how to re-point to sandboxes |
| App settings | Default permission mode is `default`; keep-awake applies only while a session is working | An unattended run stalls at its first permission prompt unless the user switches the default to Auto (§4) |

## 3. Decisions

On 2026-10-12 the user delegated every decision ("you can do anything you want, complete the
whole setup along with the documentation"). The recommended defaults are therefore **APPROVED**
for values and local work.

**DELEGATED** (D10, D11) means the user chose it, but an unattended session may act on it
**only if its own task prompt explicitly grants that authority**. The prompts in
`docs/sessions/` grant it. The Session 1 task currently scheduled does not.

| # | Decision | Value | Status |
| --- | --- | --- | --- |
| D1 | Product naming (this repository is public) | App `SF_DevOps` (label "SF DevOps"), source dir `sfdevops-app/`, branch `platform/sfdevops-app`. Keep the `CDO_` object prefix. No third-party or corporate branding anywhere | APPROVED |
| D2 | Org mapping | source `dev` → `sfp-dev`. Chain `int` → `sfp-int`, `qa` → `sfp-qa`, `stage` → `sfp-stage`. Prod → `sfp-prod` | APPROVED |
| D3 | Hub org | **Separate.** Create scratch org `sfp-hub` from DevHub `partner-pbo` (30 days) | APPROVED |
| D4 | Metadata API version | `66.0` (as in the spec). Orgs accept it. Bump later by editing the config only | APPROVED |
| D5 | Branch names | Prod/baseline = `main` (the default branch, which `schedule` triggers need). Env branches `int`, `qa`, `stage`. Hub app on `platform/sfdevops-app` | APPROVED |
| D6 | Coverage threshold | 85 | APPROVED |
| D7 | Notifications | Build `webex-notify.sh` with `notifications.webex: false`. It must no-op cleanly when off | APPROVED |
| D8 | SonarQube | Build the gate. It skips with a visible warning while `SONAR_TOKEN` is absent. The user may add SonarCloud later | APPROVED |
| D9 | Tool installs | **Install nothing on this machine.** Python, PyYAML and sfdx-git-delta are verified on GitHub runners | DECIDED (no installs) |
| D10 | GitHub write access: push to `main`, create `int`/`qa`/`stage`/`platform/*`, open PRs, create environments (`prod` with required reviewer `muraliseelam`), branch protection | Allowed when the task prompt grants it | DELEGATED |
| D11 | Salesforce org writes: create `sfp-hub`; deploy Connected App or External Client App, sample metadata and the hub app; run tests; seed records | Allowed when the task prompt grants it. **Use each org's existing admin user as the integration user. Never create users** | DELEGATED |
| D12 | Second GitHub account (Write role) | None. The non-admin label path is proven by tests of the gate logic, and the docs say so plainly | APPROVED |
| D13 | Commit identity | `Murali Seelam <murali.reddy60@gmail.com>` | APPROVED |
| D14 | Test user in `sfp-hub` for the "only `CDO_Developer_Access`" App Launcher check | Claude does not create users (hard limit). Verify the grants by API (app visibility, tabs, objects, classes in the group). The live click-check is open until the user creates a test user with one documented command | DECIDED |
| D15 | Reviews, merges and approvals | The user said "act as my agent, review and approve everything". Claude reviews and merges PRs, adds the admin `approved` label, and **approves the `prod` required-reviewer gate for test runs** | APPROVED |

### Hard limits that hold whatever the delegation says
- Claude never enters, prints, logs or commits a credential: a private key, consumer key or
  secret, PAT or token. Every credential goes through `bootstrap-secrets.sh` (below), which
  the **user** runs and which never echoes a value.
- Claude never creates accounts, whether GitHub accounts, SonarCloud accounts or Salesforce users.
- The production required-reviewer gate is approved by Claude for test runs (D15). The run
  must visibly *wait* at the gate before Claude approves it, because that wait is the
  acceptance evidence.

## 4. User steps

### Tonight, before 04:30 (without these, Session 1 cannot run unattended)
1. Settings → Claude Code → set the default permission mode to **Auto**. Otherwise the run
   stops at its first command and waits for a click.
2. Leave the PC plugged in with the lid open, Windows sleep set to "Never" for tonight, and the
   Claude app open. A scheduled task fires only while the app runs and the machine is awake.

### Morning, about 10 minutes, before Session 2
3. On github.com, create a **fine-grained PAT** for `muraliseelam/sfdevops-app` with
   Actions RW, Contents RW, Pull requests RW, Metadata R, and Workflows RW.
4. Run `bash sf-pipeline/scripts/bootstrap-secrets.sh` (Session 1 writes it). The script:
   - generates the JWT key and cert in `%USERPROFILE%\.sfdevops\`, outside the repo
   - deploys the Connected App, or the External Client App as fallback, with the cert to every
     org, using the existing CLI auth
   - reads each consumer key
   - sets `SF_CONSUMER_KEY`, `SF_USERNAME`, `SF_INSTANCE_URL`, `SF_JWT_KEY` in GitHub
     Environments `dev`, `int`, `qa`, `stage`, `prod-validate` and `prod`
   - sets `HUB_CONSUMER_KEY`, `HUB_USERNAME`, `HUB_INSTANCE_URL`, `HUB_JWT_KEY` repo secrets
   - prompts once (hidden input) for the PAT, then stores it as the `GH_PAT` secret and in the
     hub's `GitHub_API` External Credential

   It prints names only, never values.
5. During Session 2, click **Approve** on the production release when GitHub asks.

## 5. Spec gaps and how they are resolved

1. **Object count.** §2 says 23 `CDO_*` objects, but §9.1 lists 22. Build the 22, plus
   `CDO_Settings__c` as a hierarchy custom setting if that fits better. Record the gap in
   PRODUCT-DESIGN.md.
2. **LWC Jest gate.** §10 has it but `quality_gates` has no key for it. Add `quality_gates.jest: true`.
3. **Prod canary test.** `AIAssistantForSalesControllerTest` does not exist here. The sample
   `force-app` ships `PipelineCanaryTest`, and `production.destructive_tests` names it.
4. **`sf-int-deploy.yml`.** The filename contains an env name, yet §16 forbids hardcoding one.
   Keep the spec filename, keep its contents generic (it acts on whichever env is `r_is_entry`),
   and note this in the docs.
5. **Scheduled workflows** only run from the default branch. The baseline is `main` (D5).
6. **Single-user repo.** GitHub blocks a PR author from approving their own PR, so live entry
   approvals use the admin `approved` label (D12).
7. **Business metadata.** Create a small sample in `force-app/`: a custom object and fields,
   Apex classes with and without tests, a trigger, an LWC with a Jest test, a profile, a
   permission set, and `PipelineCanaryTest`.
8. The §2 diagram draws `dev` inside the chain. It is a *source* org only.
9. **Connected App creation restriction.** Recent Salesforce releases restrict creating *new*
   Connected Apps. Session 1 probes this with a check-only deploy, using a throwaway cert whose
   key is deleted immediately and never uploaded. If Connected Apps are blocked, use an External
   Client App (JWT bearer + certificate) and document the deviation from §12.2.
10. `PRs opened with GITHUB_TOKEN do not trigger workflows.` `sf-open-pr` and every
    cross-branch push use `GH_PAT`.

## 6. Sessions

Every phase ends with evidence (exact commands and real output) in `docs/build-log/session-N.md`.

### Scheduled task status (2026-10-12 23:50 CDT)
- Desktop task `sfdevops-session-1` fires 2026-10-13 04:30 CDT with its **original, local-only
  prompt**. The app's safety check blocked replacing that prompt with the full-scope one, and
  also blocked creating `sfdevops-session-2`.
- **If a session's prompt is local-only, its prompt wins.** It does the local subset: steps 1,
  3, 4, 5 and 6 (write files only, no deploy), step 7 (write the script, do not run the probe),
  step 8 (write the hub app source on a local `platform/sfdevops-app` branch, with no org work)
  and step 11 (drafts). It commits locally, never pushes, writes to no org, and marks every
  Python script "verification pending: runs in ci-selftest once pushed".
- Full scope needs the user to paste `docs/sessions/session-1-prompt.md` into the Session 1
  task and add a Session 2 task with `docs/sessions/session-2-prompt.md`, or to allow the
  scheduled-tasks tools so Claude can do it.
- Update 2026-10-13 00:05 CDT: the safety check also blocked an in-session 04:30 timer
  (CronCreate, reason "Auto-Mode Bypass") and the keep-awake request. **Claude cannot arrange
  its own deferred, unattended start.** Two ways remain, and the user chooses:
  1. **Start now, live** in the planning session (Auto mode, every action still reviewed), and
     keep working through the night. Disable `sfdevops-session-1` first so two agents never
     touch the repo at once.
  2. **Keep 04:30.** The user switches the permission mode to Auto and pastes
     `docs/sessions/session-1-prompt.md` into the Session 1 task.

### Session 1 — 04:30 CDT, unattended: build everything that does not need credentials
Commit to `main` in small commits and push. The repo is greenfield and protection comes last.
Order:
1. **Phase 1:** skeleton (§3 of the spec), `sfdx-project.json`, `.forceignore`, `.gitignore`
   (ignores `sfdevops-app/`, `server.key*`, `.sfdevops/`), `pipeline.config.yml` with the D-values,
   and `plan.py`, plus fixture configs for 3 and 5 environments.
2. **Self-test workflow** `ci-selftest.yml` (push and dispatch, no secrets). It runs every Python
   and bash script's fixture tests on `ubuntu-latest`: `plan.py` on both fixtures, `specified_tests.py`
   passes 2 and 3 plus pass 1 against a fixture coverage map, `profiles.py` full and
   incremental, `deploy_report.py` (including "non-zero exit but Succeeded"), `manifest_to_md.py`,
   `conflict-check.py`, and `delta.sh` with the real sfdx-git-delta on a synthetic commit range,
   proving the `source_path` scoping and the `.forceignore` toggle.
   Also `actionlint` on every workflow. Push, watch it, fix until green, and record the run URL.
3. **Phase 5:** `promote/action.yml` plus `sf-pipeline/tests/promotion-sim.sh`, a pure git
   simulation run locally and in CI. Proves (a) no clobber, (b) a conflict aborts, lists paths
   and exits non-zero, (c) the post-deploy merge refuses when the target moved.
4. **All scripts** from spec §3 and §8, and **all composite actions** (`deploy`, `quality`,
   `report`, `promote`).
5. **All 17 workflows** from spec §6, with least-privilege `permissions:`, `plan.py`-driven
   environments, concurrency per env branch, and a hub callback at every terminal state.
6. **Sample `force-app`** (gap 7), deployed check-only to `sfp-int` with the local CLI as a smoke test.
7. **`bootstrap-secrets.sh`** (§4 step 4). Test every non-secret code path. Probe the Connected
   App restriction (gap 9).
8. **Hub app:** create `sfp-hub`. On branch `platform/sfdevops-app`, build, in order: objects →
   permission sets and groups → Apex services → controllers → tests → LWCs → quick actions →
   layouts → flexipages → tabs → app. Then the External Credential and Named Credential
   `GitHub_API` *without* a token, and the callback endpoint. Deploy to `sfp-hub`, run all Apex
   tests there, and record coverage. Verify the CDO_Developer_Access grants by API (D14). Open
   the app in the browser pane as the admin and screenshot every tab and page.
   Mind the traps: Percent defaults, app visibility, PSG description ≤255 characters,
   quick actions deployed before layouts, and no two `@AuraEnabled` methods with the same name.
9. `seed-pipeline.py`: generate the Project, Stage and Environment records from the YAML. Run
   it from a workflow, or produce `sf data import tree` JSON locally if Python is needed.
   Load them into `sfp-hub` and verify they match the YAML.
10. **GitHub setup:** environments `dev`, `int`, `qa`, `stage`, `prod-validate`, and `prod`
    with required reviewer `muraliseelam`. Create `int`/`qa`/`stage` from the finished `main`.
    Apply `setup-branch-protection.sh` **last**, after the final push to `main`. Make sure the
    automation (with `GH_PAT`) can still merge into env branches. Prove this in Session 2.
11. **Docs, first full drafts:** `PRODUCT-DESIGN.md` (decisions and their costs, plus traps),
    `PIPELINE-USER-GUIDE.md`, `DEVOPS.md`, `SETUP.md` (including the user steps and how to
    re-point from scratch orgs to sandboxes), and drawio diagrams for architecture, branching and
    change flow, with PNG exports if a local exporter is available, otherwise SVG.

If time or context runs out, stop at a clean commit and log exactly where Session 2 must resume.

### Session 2 — 09:00 CDT (or "Run now"): live end-to-end, then final docs
1. Check prerequisites first: `gh secret list` shows `GH_PAT` and `HUB_*`, and each environment
   shows its four secrets. If anything is missing, stop and report exactly which §4 step is left.
2. **Phase 2:** an auth smoke workflow runs `sf org display` against every org.
3. **Phases 3–4 live:** a one-field PR gives a one-component manifest and a green check-only
   run. A one-class change runs only its tests. A no-test class fails with a useful message.
4. **Phase 6:** an admin `approved` label on an entry PR starts the entry promotion automatically.
5. **Phase 7:** a story-level promotion through `int → qa → stage`. Include the drift test (the
   target's own change survives), the conflict case (abort, comment, fail, work item blocked)
   and the target-moved refusal.
6. **Phase 8:** a prod release: `prod-validate` → waits for the user's Approve → quick-deploy of
   the validated id → merge → tag → release. A destructive-only change deploys with the canary.
7. **Phase 9:** coverage below threshold fails. The bypass label works for an admin, with the
   permission re-verified at run time.
8. **Phase 11:** an action in the hub UI dispatches a workflow (204), the run calls back, and
   the records and audit event update. The `Running`→`Success` pair leaves one deployment row.
   Junction rows are written at every promotion entry point.
9. **Phase 12:** live runs of the conflict check, sync, ops workflows and data deploy.
10. **Final docs:** update every doc with real run URLs. Write `docs/ACCEPTANCE.md`, mapping
    each §16 item to its evidence, and mark honestly what is proven by tests only (D12, D14).

## 7. Session rules (apply to every session)

- Never hardcode an environment name, branch name or org count outside `pipeline.config.yml`.
- Never claim something works without command output that shows it.
- Small commits, Murali Seelam identity, no Claude or Anthropic attribution anywhere
  (commits, PRs, tags, releases, comments).
- Never print, log or commit a credential (§3 hard limits).
- At the end of each session, append to the progress log below: done, verified, open, blocked.

## 8. Progress log

- 2026-10-12 23:20 CDT: first plan written.
- 2026-10-12 23:45 CDT: user delegated all decisions. Plan revised into Session 1 (unattended
  build) and Session 2 (live end-to-end and final docs). No code yet.
- 2026-10-12 23:50 CDT: the safety check blocked the task update and the Session 2 task.
  Full-scope prompts saved in `docs/sessions/`. The Session 1 task is still local-only.
- 2026-10-13 00:05 CDT: the user asked for full autonomy (reviews, merges, approvals) and an
  open-source-ready result (§1b, D15). The in-session timer and keep-awake were blocked too.
  Waiting for the user to choose "start now" or "keep 04:30" (§6). `sfdevops-session-1` is
  enabled with its local-only prompt.
