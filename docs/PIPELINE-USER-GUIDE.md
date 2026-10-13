# Pipeline user guide

For developers and release managers. It explains how a change travels from your developer org to
production, what you click, what runs, what each status means, and what to do when something
stops it. Operators should also read [DEVOPS.md](DEVOPS.md); the design rationale is in
[PRODUCT-DESIGN.md](PRODUCT-DESIGN.md).

Examples use the reference chain `int → qa → stage → prod`, the developer org `dev`, and branch
`main` as production. Your project may name them differently; the behaviour is the same.

---

## Words used here

| Word | Meaning |
| --- | --- |
| **Work item** | One change, `WI-0001`, in the hub. It carries commits and components |
| **Source org** | A developer org you commit from (`dev`). Nothing is deployed to it |
| **Environment / stage** | An org in the chain and its position: `int` (the **entry** stage), `qa`, `stage`, then `prod` |
| **Environment branch** | The git branch that describes an environment's org: `int`, `qa`, `stage`; `main` for production |
| **Feature branch** | `feature/WI-0001`, cut from `main` on the first commit |
| **Promotion** | One hop of one or more work items into one stage (`PRM-00001`) |
| **Promotion branch** | `promotion/WI-0001-to-qa`, cut from the **target** branch with the feature merged in; it is exactly what gets deployed |
| **Release** | Work items that go to production together, assembled on `release/<name>` |
| **Validation** | A check-only deploy: tests run, nothing changes in the org |

The one rule to remember: **a branch is merged only after its org was deployed.** The pull request
is where your change is reviewed; it is never merged with its merge button. The pipeline merges.

---

## The life of a work item

### 1. Create the work item

Hub: **App Launcher → SF DevOps → Pipeline → New work item**. Fill in Subject, Project and
**Source org** (the developer org you work in). Optional: Description, Acceptance criteria, Story
points, Release, **Minimum coverage (%)**, **Specified tests**, **Test level override**.

Status: **New**.

### 2. Build in your developer org, then list your changes

Make your changes in the source org. On the work item, in **Commit changes**, pick the source org
and click **List changes**. The hub dispatches `sf-list-changes`, which reads the org's
`SourceMember` records (the org's own change tracking) and sends back every changed component,
newest first, with who changed it and when. Use the filter and the metadata-type picker to find
yours.

### 3. Commit

Select the components that belong to this work item, write a commit message and click **Commit**.
`sf-commit`:

- cuts `feature/WI-0001` from `main` the first time (so your work starts from production, not from
  an environment holding other people's unreleased work);
- retrieves **only the components you selected** from the source org;
- drops anything on the deny-list (`ConnectedApp`, `NamedCredential`, `ExternalCredential`,
  `AuthProvider`, `Certificate`, `Settings`, `InstalledPackage`, `SamlSsoConfig`: credentials and
  org-wide settings never go into a feature branch);
- removes the files of components marked as deleted;
- commits `[WI-0001] <your message>` and pushes.

The hub records the commit and each component (`Add`, `Modify` or `Delete`, its Unique ID
`Type:Member`, last commit date and SHA). Status: **Committed**. If the org's copy already matches
the branch, the run says "nothing to commit".

Commit as often as you like; each commit adds to the same feature branch.

### 4. Open the pull request

Click **Open pull request**. `sf-open-pr` opens (or reuses) the PR from `feature/WI-0001` into the
**entry** branch (`int`) and links it on the work item. Status: **In Review**.

To name Apex tests for the validation and the entry deploy, add a line to the **PR description**:

```text
Specified-Tests: InvoiceServiceTest, InvoiceTriggerHandlerTest
```

(See [Naming tests](#naming-tests).)

### 5. Validation runs on the PR

Every time the PR is opened, updated or reopened, `sf-pr-validation` runs:

1. **Changes:** cuts `promotion/WI-0001-to-int` from `int`, merges your feature into it, and
   computes the delta between `int` and that merge. A merge conflict stops here (see
   [Conflicts](#a-merge-conflict)).
2. **Quality** (only for what changed): PMD for Apex, LWC Jest for LWC bundles, SonarQube for Apex
   or LWC/Aura JavaScript when configured.
3. **Validate:** a check-only deploy of that delta to `int`, running the tests that cover your Apex
   and checking coverage against the threshold (85 % by default).

A sticky PR comment **Validation against `int`** reports the outcome, the deploy id, the test level
and tests, coverage, failing tests and the component manifest. It is updated in place on every run.
In the hub the work item shows **Last Validation Status** (Running / Passed / Failed), **Last
Coverage**, whether tests passed, the run link, and any PMD findings. To run it again without a new
commit, click **Validate** on the work item.

Draft PRs are not validated until marked ready. PRs from forks get no org secrets and are skipped.

### 6. Approval

| Stage | Who can approve |
| --- | --- |
| Entry (`int`) | A reviewer approves the PR in GitHub, **or** a repository admin or maintainer adds the `approved` label |
| `qa`, `stage` | You, self-service, from the hub |
| Production | The required reviewer of the `prod` GitHub Environment |

GitHub does not let you approve your own PR. If a developer without admin rights adds the
`approved` label on an entry PR, the pipeline removes it and comments why; nothing deploys.

**Approve after the validation is green.** The approval starts the deploy by itself, but only if the
latest validation of the PR's head commit passed and its coverage met the threshold. Otherwise the
PR gets "Approval recorded, but the deploy to `int` is held: …". Fix the cause, wait for a green
validation, and approve again (submit another approving review, or remove and re-add the label).

The hub records the approval (`CDO_Approval__c`, review state **Approved**, status **Approved**).

### 7. Entry deploy and merge

Approval starts `sf-int-deploy`:

1. cuts `promotion/WI-0001-to-int` from `int` and merges your feature;
2. deploys the delta to the `int` org (Apex changes are validated first, gated on coverage, then
   quick-deployed from the validated id);
3. **only after a successful deploy**, merges the promotion into `int`. If `int` moved during the
   run, the merge is refused (see [Refused merge](#a-refused-merge-target-moved)).

The PR gets **Deployed to `int` and merged** and GitHub shows it as merged (its commits are now on
`int`). In the hub, the entry promotion and its deployment are recorded, the work item's **Current
Stage** becomes `int` and its status **Deployed**.

### 8. Promote to `qa`, then `stage`

On the work item, click **Promote & Deploy** (or **Promote** to create a Draft you deploy later from
the promotion record). The **Pipeline** tab and the promotion record page offer the same, and let
you promote several work items together.

The hub queues the promotion. `CDOPromotionDispatcher` keeps **one promotion in flight per stage**
and dispatches the oldest queued one first, so promotions wait their turn instead of colliding.
`sf-promotion` cuts `promotion/WI-0001-to-qa` from `qa`, merges only your feature branch, deploys
`delta(qa at cut .. promotion)`, and merges into `qa` after success. The work item moves to `qa`.
Repeat for `stage`.

Options on the promotion: test level, specified tests (default: the work items' **Specified
tests**), **Validate only** (check-only, never merges), and whether deletions apply.

The QA package can differ from the INT package for the same work item. That is correct: each is the
difference between *that* environment and your change.

### 9. Assemble the release

Release managers: **Release Board** → **New release** (name, project, target date) → add work items
→ **Assemble**. `assemble-release` cuts `release/<name>` from `main` and merges **only those work
items' feature branches**, so production receives exactly what was planned. A conflict fails the
assembly and reports the conflicting paths. Status: Planned → **Assembling** → **Ready** (or
**Failed**).

### 10. Release to production

**Release to Production** (needs the `CDO_Run_Prod_Release` permission, part of the release manager
group). `sf-prod-release`:

1. cuts `promotion/release-<name>-to-prod` from `main`, merges the release branch, and **validates**
   it against production in `prod-validate` (no reviewer). Release status **Validating**.
2. waits for the **required reviewer** of the `prod` GitHub Environment. Approve it in GitHub:
   **Actions → the run → Review deployments → prod → Approve and deploy**. The reviewer approves a
   payload that has already passed.
3. rebuilds the tree from the recorded commits, proves it is identical to the validated one,
   **quick-deploys the validated deploy id** (no second test run), merges into `main`, tags
   `release-<name>` and publishes a GitHub Release with the manifest.

The release becomes **Released** and its work items **Done**. (The release flow end to end, assembly
through the hub's release statuses, is **Evidence: pending live run**.)

Production refuses Apex that no test covers. A deletion-only or no-Apex release runs the canary test
(`PipelineCanaryTest`), because production never accepts `NoTestRun` when Apex is involved.

---

## Status reference

### Work item `Status__c`

| Status | Means | Set by |
| --- | --- | --- |
| New | Created, nothing committed | creation |
| In Progress | Being worked on | you |
| Committed | At least one commit on the feature branch | commit callback |
| In Review | A PR is open | PR callback |
| Approved | The PR was approved | approval callback |
| Promoting | Reserved for "a promotion is under way"; the current hub code does not set it (watch the promotion's status instead) | — |
| Deployed | Deployed and merged into its current stage | deploy callback |
| Blocked | A deploy failed or a merge conflicted; see **Blocked Reason** / **Conflict Paths** | failure or conflict callback |
| Done | Released to production | release callback |
| Cancelled | Abandoned | you |

Other work item fields: **Merge State** (Not Merged / Merged / Conflict), **Review State** (Pending
/ Approved / Changes Requested), **Last Validation Status** (Not Run / Running / Passed / Failed),
**Source Changes Status** (Idle / Requested / Received / Failed).

### Promotion `Status__c`

| Status | Means |
| --- | --- |
| Draft | Created with **Promote**; not queued yet. Deploy it from the promotion record |
| Queued | Waiting for its stage to be free |
| Dispatched | GitHub was asked to run it. This is **not** proof that it started |
| Deploying | The workflow reported that it is running (only a callback sets this) |
| Deployed | The org was deployed. Check the audit trail for the merge result |
| Failed | The deploy failed (or the workflow never started, found by the reconciler) |
| Conflict | The promotion merge conflicted |
| Cancelled | You cancelled it |

A promotion's work items each have a junction row (Pending / Deployed / Failed / Conflict).

### Deployment, release and environment

- **Deployment** `Status__c`: Running / Success / Failed / Cancelled, with event type Commit,
  Validation, Deploy, QuickDeploy, Rollback or Data, the deploy id, coverage, tests passed and
  failing methods. A `Running` then `Success` pair is one row.
- **Release** `Status__c`: Planned → Assembling → Ready → Validating → Releasing → Released, or Failed
  / Cancelled.
- **Environment** `Health_Status__c`: Healthy after a successful deploy, Degraded after a failed one;
  **blank** until something has been deployed there.

---

## Reading the PR comments

The pipeline keeps **one comment per environment and kind**, updated in place.

| Comment | From | What it tells you |
| --- | --- | --- |
| **Validation against `int`** | `sf-pr-validation` | Outcome (`success`, `failure`, `no_changes`), deploy id, test level, the tests that ran, coverage (or why it is blank), failing tests as `Class.method: message`, commit, run link, the component manifest (additions and deletions by type) |
| **Deployed to `int` and merged** | `sf-int-deploy` | The same fields for the real deploy; a **Merge:** line explains a merge that did not happen |
| **Merge conflict promoting WI-0001 to `int`** | the promote step | The conflicting paths. Nothing was deployed or merged |
| **Approval recorded, but the deploy … is held** | `sf-int-deploy` | Why the approval did not start a deploy |
| **the entry stage needs a real review …** | `sf-int-deploy` | Your `approved` label was removed (not an admin) |
| **the `bypass-quality-gates` label is honoured only from repository admins …** | validation / deploy | Your bypass label was removed |

Each comment ends with hidden markers (`<!-- sfdevops:... -->`). Leave them: the approval step reads
the latest validation marker for the PR's head commit.

The job summary of each run (Actions → run → Summary) carries the same report plus the test
resolver's explanation of how each test was chosen.

---

## Naming tests

Most of the time you name nothing. For each changed Apex class or trigger the pipeline finds the
tests in three passes:

1. **The org's coverage map** (`ApexCodeCoverage`): the tests that actually exercise the class,
   most lines covered first, at most 25 in total across the change.
2. **Naming convention**, against test classes in the repository: `FooTest`, `Foo_Test`, `TestFoo`,
   `Test_Foo`, `FooTests`, `Foo_Tests`, `FooTestClass`.
3. **Changed test classes** themselves.

`RunSpecifiedTests` counts coverage only from the tests that ran, so a class covered only by a test
that was not named scores zero. Name tests explicitly when the resolver cannot know:

| Where | Applies to |
| --- | --- |
| A `Specified-Tests: A, B` line in the **PR description** | PR validation and the entry deploy |
| The work item's **Specified tests** field | Hub promotions to later stages (the union across the promotion's work items) and the production release (the union across the release's work items) |
| The promotion's **Specified tests** option, or `specified_tests` on a manual dispatch | That promotion or release |

The two are separate: the hub does not copy the work item's field into the PR description, so put the
line in the PR description too if you need it at the entry stage.

Write the class names on the same line as `Specified-Tests:` and never leave the line empty: the
pipeline reads the first line of the description that starts with `Specified-Tests:`, and an empty
one makes it read the following line as test names.

Explicit tests win over automatic resolution (only the admin bypass comes before them).

### "No covering test"

When nothing resolves for a changed class:

| Target | Result |
| --- | --- |
| A validation | **Fails**, naming the class: "No Apex test covers Foo. Add a test class (for example FooTest) or name one in the work item's Specified Tests." |
| A sandbox deploy | Deploys with `NoTestRun` and a warning; coverage is blank |
| Production | **Refused**: Apex with no covering test does not ship |

Fix it by adding a test class that follows the naming convention, or by naming the right test (see
the table above). The pipeline never falls back to running every test in the org.

---

## When something stops your change

### A merge conflict

Your feature and the target branch changed the same lines. The promotion merge is aborted, the
conflicting paths are commented on the PR and recorded on the work item (**Conflict Paths**, status
**Blocked**, merge state **Conflict**), and nothing is deployed or merged.

Resolve it on your feature branch:

```bash
git fetch origin
git switch feature/WI-0001
git merge origin/int          # the target the comment names
# fix the conflicts, then
git add -A && git commit
git push
```

The push re-runs the validation. Then approve again (entry) or promote again (later stages).

`sf-conflict-check` warns earlier: it lists work items that touch the same components (from git and
from the hub) on every feature-branch push and every three hours, and flags the overlapping
components on each work item. An overlap is a warning, not a failure.

### A failed coverage gate

The validation (or deploy) says coverage is below the threshold, or tests failed. In a real deploy,
Apex changes are validated first, so a failed gate deployed **nothing** and merged nothing.

- Read **Failing tests** in the PR comment (`Class.method: message`).
- Check **Tests**: if the class's real test was not named, coverage counts as zero for it. Name it.
- Add test coverage, push, and approve or promote again.

### "No covering test"

See [above](#no-covering-test).

### A refused merge (target moved)

"Merge refused: … moved during the run." Another promotion merged into the same environment branch
while yours deployed. The org has your deploy, but the branch was **not** merged, because merging
would publish a tree that was never deployed. Promote again: the new run cuts from the new target
head, so it contains both changes, deploys, and merges.

### The approval was held

See [Approval](#6-approval). The held reason is in the PR comment and in the work item's approval
record.

### A deploy failed

The PR or promotion record links the run. The report lists component failures and failing tests. In
the hub the promotion is **Failed**, the work item **Blocked** with a reason, and the environment
**Degraded**. Fix the cause on the feature branch and promote again.

---

## Bypassing quality gates (admins only)

A repository admin or maintainer can add the `bypass-quality-gates` label to a PR. Its effect,
re-verified against the GitHub permissions API at run time:

- PMD, Sonar and Jest findings are reported but do not fail the run;
- tests and the coverage gate are skipped for sandbox validations and deploys (`NoTestRun`);
- production still runs its canary test when Apex is involved.

Anyone else's bypass label is removed with a comment. Use it for emergencies, and expect it in the
audit trail.

---

## Operations

In the hub: **Pipeline → Governance → Operations** (needs `CDO_Governance_Ops`). Each runs a
workflow; you can also dispatch them from GitHub.

| Operation | Workflow | What it does |
| --- | --- | --- |
| **Roll back** an environment to a known-good commit | `sf-ops-rollback` | Cuts a promotion branch from the environment branch, restores the source tree to that commit (files changed since are restored, files added since are deleted), deploys that delta (deletions included), and merges the restoring commit only after the deploy. History keeps both the bad change and its rollback. Production uses its reviewer-gated environment. Requires a reason |
| **Redeploy** a feature to an environment | `sf-ops-redeploy-feature` | Exactly a story-level promotion (after an org refresh, or after a cancelled run) |
| **Recreate** a feature branch | `sf-ops-recreate-feature` | Cuts a fresh branch from `main` and carries over only the work item's files (or the paths you give). The old branch is kept as `backup/<branch>-<timestamp>` |
| **Sync** environment branches with the baseline | `sync-env-branches` | After a release, each environment gets a normal promotion: merge `main` into it, deploy, merge after success. Set deploy to false to validate and report only |
| **Run conflict check** | `sf-conflict-check` | The overlap report described above |

From GitHub:

```bash
gh workflow run sf-ops-rollback.yml -f target_env=qa -f sha=<known-good sha> -f reason="Revert WI-0042"
gh workflow run sf-ops-redeploy-feature.yml -f work_item=WI-0001 -f target_env=qa
gh workflow run sf-ops-recreate-feature.yml -f work_item=WI-0001
gh workflow run sync-env-branches.yml                      # every environment
gh workflow run sync-env-branches.yml -f target_env=qa -f deploy=false
```

---

## Data deploys

Records, not metadata. **Data Deploy** tab: create a data set, add a template per object (object API
name, fields, filter, **external id field**, order, record limit) and relationships between
templates, then **Deploy data** from one environment to another.

`sf-data-deploy` exports each template from the source org with the Bulk API and upserts it into the
target **by external id**, parents before children. Lookups travel as `<Relationship>.<parent
external id>` (for example `Account.External_Id__c`), because Salesforce Ids differ between orgs.
So every object you move needs an external id field populated in the source. A target of production
runs in its reviewer-gated GitHub Environment.

---

## Other things on the work item

- **Deployment steps**: manual or scripted Pre / Deploy / Post steps to remember for a release
  (instructions, type, status). They are a checklist; the pipeline does not execute them.
- **Test scripts and results**: manual test steps per stage, and their outcomes (Pass / Fail /
  Blocked / Not Run).
- **Delivery Metrics** tab: DORA-style weekly metrics from the deployment records.
- **Audit Events** tab: the append-only history. Every callback and every hub action of
  consequence writes one; nobody can edit or delete them.

---

## FAQ

**Can I merge my PR with the merge button?** No. Branch protection requires the `sfdevops/deploy`
status, which only the pipeline sets on a deployed promotion. Approve it; the pipeline merges.

**Why does my PR show as merged when I never merged it?** The promotion carried your commits into
the environment branch, so GitHub sees them on the base branch.

**Why did the promotion branch disappear?** It is local to the run when a direct push merges it.
When protection forces the PR path, the pipeline pushes it, merges the PR and deletes it.

**Can two people promote to `qa` at once?** From the hub, yes: the second waits in the queue. Two
direct GitHub dispatches to the same environment share one concurrency group, where a third arrival
evicts the waiting one.

**Who is the author of the pipeline's commits?** Commits the pipeline creates (feature commits,
promotion merges, rollbacks) are authored as `github-actions[bot]`, with the requester named in the
commit message. A merge through a promotion PR is recorded by GitHub under the token's identity
(`GH_PAT` owner, or `github-actions`).
