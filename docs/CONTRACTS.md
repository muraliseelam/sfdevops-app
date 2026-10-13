# Contracts — how the hub, the workflows and the scripts fit together

This is the reference every part of the platform is built against. If you change a contract,
change both sides in the same pull request and update this file.

- **Hub** = the Salesforce app on branch `platform/sfdevops-app` (`CDO_*` objects, Apex, LWC).
- **Pipeline** = `.github/workflows/*` plus `sf-pipeline/*` on the baseline branch.
- They talk over exactly two contracts: **outbound** `workflow_dispatch` (hub → GitHub) and
  **inbound** REST callbacks (GitHub → hub). Nothing else crosses the boundary.

---

## 1. Outbound — `GitHubService.dispatchWorkflow`

```
POST callout:GitHub_API/repos/{owner}/{repo}/actions/workflows/{workflowFile}/dispatches
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
Content-Type: application/json
{ "ref": "<gitRef>", "inputs": { ...string values only... } }
→ 204 No Content. Anything else is a failure.
```

- `owner`, `repo`, `ref` and the Named Credential name come from the hierarchy custom setting
  `CDO_Settings__c` (`GitHub_Owner__c`, `GitHub_Repo__c`, `Workflow_Ref__c`, `Named_Credential__c`).
- The Named Credential `GitHub_API` (URL `https://api.github.com`) uses the External Credential
  `GitHub_API_Credential` (Custom protocol, named principal `GitHub_PAT`, parameter `Token`). It
  sends the header `Authorization: Bearer {!$Credential.GitHub_API_Credential.Token}`. The token
  is set by `sf-pipeline/scripts/bootstrap-secrets.sh`, never by hand-edited metadata.
- **Every input value is a string.** `GitHubService` takes `Map<String, String>`, so a
  non-string cannot be sent.
- Dispatch is a callout, and a callout cannot follow DML in the same transaction, so every
  dispatch runs in a `Queueable` that implements `Database.AllowsCallouts`.
- **An Apex record's status is not evidence that the workflow started.** Only a callback writes
  the run URL (`Workflow_Run_URL__c`). Anything that needs to know whether a run is in flight
  checks for the run URL.

### Workflow inputs (all strings; blank = use the default)

| Workflow file | Inputs |
| --- | --- |
| `sf-commit.yml` | `work_item`, `work_item_id`, `source_org`, `components` (JSON array `[{"type":"ApexClass","name":"Foo"}]`), `commit_message`, `feature_branch` |
| `sf-list-changes.yml` | `work_item`, `work_item_id`, `source_org`, `request_id` |
| `sf-open-pr.yml` | `work_item`, `work_item_id`, `feature_branch`, `title`, `body` |
| `sf-pr-validation.yml` | `pr_number`, `work_item`, `work_item_id` |
| `sf-int-deploy.yml` | `pr_number`, `work_item`, `work_item_id`, `approver`, `method` (`review`/`label`/`manual`) |
| `sf-promotion.yml` | `promotion_id`, `work_items` (comma-separated keys), `feature_refs` (comma-separated, optional), `target_env`, `test_level`, `specified_tests`, `check_only` (`true`/`false`), `allow_destructive` (`true`/`false`) |
| `sf-promote.yml` | `target_env`, `test_level`, `check_only`, `promotion_id` |
| `sf-prod-release.yml` | `release_id`, `release_name`, `source_ref`, `test_level`, `specified_tests`, `allow_destructive` |
| `assemble-release.yml` | `release_id`, `release_name`, `work_items` |
| `auto-merge-approved.yml` | `target_env` |
| `sf-conflict-check.yml` | `work_items` |
| `sf-data-deploy.yml` | `data_set_id`, `source_env`, `target_env`, `plan` (base64 JSON, §5) |
| `sf-ops-rollback.yml` | `target_env`, `sha`, `test_level`, `reason` |
| `sf-ops-redeploy-feature.yml` | `work_item`, `work_item_id`, `target_env`, `feature_ref` |
| `sf-ops-recreate-feature.yml` | `work_item`, `work_item_id`, `feature_branch`, `paths` |
| `sync-env-branches.yml` | `target_env` (blank = all), `deploy` (`true`/`false`) |

`target_env`, `source_env` and `source_org` are **pipeline keys** from `pipeline.config.yml`
(for example `int` or `prod`). They are `CDO_Environment__c.Pipeline_Key__c` /
`CDO_Stage__c.Pipeline_Key__c` in the hub.

Every workflow sets a `run-name` that contains the work item key and the promotion or release
id, so `CDO_PromotionReconciler` can find a run whose callback never arrived.

---

## 2. Inbound — REST callbacks (`/services/apexrest/cdo/...`)

The runner authenticates to the hub with `sf-pipeline/scripts/auth-hub.sh` (JWT, repo secrets
`HUB_*`) and POSTs JSON with `sf-pipeline/scripts/hub-callback.sh`. If the `HUB_*` secrets are
absent, the callback scripts print a notice and exit 0, so the pipeline still runs without a hub.

### 2.1 `POST /cdo/deploy-callback` — `CDO_CallbackResource`

```apex
global class CallbackRequest {
    public String  deploymentId;       // hub Id, when the hub created the row
    public String  promotionId;        // hub Id; blank = work-item-scoped event
    public String  releaseId;          // hub Id, release events
    public String  status;             // Running | Success | Failed | Cancelled
    public String  message;
    public String  runUrl;
    public String  commitSha;
    public String  workItem;           // work item key, e.g. WI-0032 (CDO_Work_Item__c.Name)
    public String  environment;        // pipeline key, e.g. int, qa, prod
    public String  eventType;          // Commit | Validation | Deploy | QuickDeploy | PullRequest |
                                       // Approval | Conflict | Merge | Release | Data | Rollback
    public String  pullRequestUrl;
    public Integer pullRequestNumber;
    public Boolean pullRequestsApproved;
    public String  reviewState;        // Pending | Approved | Changes_Requested
    public String  approver;           // GitHub login
    public String  approvalMethod;     // Review | Label | Manual | Environment
    public Decimal coveragePercent;    // literal percent: 87.5 means 87.5 %
    public Boolean testsPassed;
    public String  failingMethods;     // newline-separated "Class.method: message"
    public String  deployId;           // Salesforce deploy job id
    public Boolean checkOnly;
    public String  testLevel;
    public Integer componentCount;
    public String  promotionBranch;
    public String  targetShaAtCut;
    public String  conflictPaths;      // newline-separated paths
    public List<ComponentPayload> components;
    public List<FindingPayload>   findings;
}
global class ComponentPayload { public String type, name, action, uniqueId, path, lastCommitDate, lastCommitSha; }
global class FindingPayload   { public String tool, rule, severity, file, message; public Integer line; }
global class CallbackResponse { public Boolean success; public String deploymentId; public String message; }
```

**Routing:** no `promotionId` → `CDO_CallbackService.applyWorkItemEvent(req)` (release events
are handled inside it when `releaseId` is set); otherwise → `CDO_CallbackService.apply(req)`.
Unknown JSON attributes are ignored (`JSON.deserialize`, not `deserializeStrict`), so the
pipeline can add fields without breaking older hubs.

**De-dup rule (learned the hard way).** Find the existing `CDO_Deployment__c` by
`Workflow_Run_URL__c` = `runUrl`. **If `runUrl` is blank or matches nothing, look for the open
`Running` deployment for the same work item (or promotion) and stage. Insert only if both
lookups miss.** So the ordinary `Running`→`Success` pair leaves one row, not two.

**Ordering:** whenever "latest" matters, order by `CreatedDate DESC, Id DESC`. A tie on
`CreatedDate` alone is broken arbitrarily, which once let a failed deployment mask a later
successful one.

**Effects of `apply` (promotion-scoped):**
- `Running`: promotion `Status__c` = `Deploying`; store the run URL, `Promotion_Branch__c` and `Target_SHA_At_Cut__c`.
- `Success` + `Deploy`/`QuickDeploy`: promotion `Deployed`, `Completed_On__c`, `Merge_SHA__c` = `commitSha`.
  `CDO_PromotionReconciler.resolvePromotedWorkItems(promotionId)` marks every junction row
  `Deployed` and moves each work item's `Current_Stage__c` to the target stage
  (`Merge_State__c` = `Merged`, `Status__c` = `Deployed`, or `Done` at production). The
  environment's `Last_Deployment__c` and `Last_Deployed_On__c` are set and `Health_Status__c` =
  `Healthy`. Then `CDOPromotionDispatcher.onPromotionFinished(promotionId)` dispatches the next
  queued promotion for that stage.
- `Failed`: promotion `Failed`, `Message__c`; work items `Status__c` = `Blocked`, `Blocked_Reason__c`;
  environment `Health_Status__c` = `Degraded`; then `onPromotionFinished`.
- `Conflict` (eventType): promotion `Conflict`; work items `Merge_State__c` = `Conflict`,
  `Status__c` = `Blocked`, `Conflict_Paths__c`; then `onPromotionFinished`.
- `Health_Status__c` is a restricted picklist (Healthy / Degraded / Down) with **no default**.
  Code that means "nothing has been deployed here yet" leaves the field alone.
- Every call writes one `CDO_Audit_Event__c`.

**Conventions and refinements (as implemented in the hub):**
- De-dup matches on `runUrl` only within the same stage and the same `checkOnly` flag, so a
  production validation and the quick deploy that follows it in the same run stay two rows.
- A repeated `Success`, or a late `Running`, for an already-Deployed promotion adds no row and
  never reopens it. A callback for a promotion that somehow has no junction row writes it.
- A successful check-only promotion is marked `Deployed` with a message saying nothing was
  deployed; no work item moves and environment health is untouched.
- Release events: `pullRequestUrl` carries the GitHub Release URL, and `Tag__c` is taken from its
  `/releases/tag/<tag>` path. Data events: `deploymentId` carries the `CDO_Data_Set__c` id, whose
  status the hub updates.
- Commit events carry no branch: `Feature_Branch__c` is filled from `featureBranch(wi)` when blank.

**Effects of `applyWorkItemEvent`:**
- `Commit`: upsert a `CDO_Commit__c` on `SHA__c`, and upsert `CDO_Component__c` on
  `Work_Item_Key__c` (= `WI-0032|ApexClass:Foo`), stamping `Action__c`, `Unique_ID__c`,
  `Last_Commit_Date__c` and `Last_Commit_SHA__c`. The work item gets `Status__c` = `Committed`,
  `Feature_Branch__c` and `Last_Commit_SHA__c`.
- `PullRequest`: `Pull_Request_URL__c`, `Pull_Request_Number__c`, `Status__c` = `In_Review`.
- `Validation`: a deployment row (`Check_Only__c` = true, with de-dup), plus `Last_Coverage__c`,
  `Last_Tests_Passed__c`, `Last_Validation_Status__c` and `Last_Run_URL__c` on the work item, and
  `CDO_Scan_Finding__c` rows from `findings`.
- `Approval`: `Pull_Requests_Approved__c`, `Review_State__c`, and a `CDO_Approval__c` row.
- `Deploy` without a promotion (an entry-hop deploy from `sf-int-deploy` that created its own
  promotion, ops redeploys, rollbacks): a deployment row with de-dup, and the environment
  health is updated.
- `Conflict` without a promotion (from `sf-conflict-check`): `Conflict_Paths__c`, and the
  overlapping `CDO_Component__c` rows get `Has_Conflict__c` = true.
- Release events (`releaseId` set): update `CDO_Release__c` status, `Release_Branch__c`,
  `Tag__c`, `Release_URL__c`, `Validated_Deploy_Id__c` and `Workflow_Run_URL__c`.

### 2.2 `POST /cdo/merge-status` — `CDO_MergeStatusResource`
`{ promotionId, workItem, environment, targetBranch, mergeSha, merged (Boolean), reason, runUrl }`.
It records the post-deploy merge outcome. `merged=false` with a reason (for example "target moved
during the run") leaves the promotion `Deployed` but writes an audit event and sets
`Message__c`, because the org was deployed but the branch was not merged.

### 2.3 `POST /cdo/source-members` — `CDO_SourceMemberResource`
`{ workItem, workItemId, requestId, sourceOrg, status, message, members: [ { type, name, lastModifiedDate, lastModifiedBy, state } ] }`.
It stores the list newest-first on the work item (`Source_Changes_JSON__c`,
`Source_Changes_Status__c` = `Received`, `Source_Changes_Received_On__c`) for the commit UI.

---

## 3. Hub data model

The machine-readable definition is `tools/objects.yml` on branch `platform/sfdevops-app`.
`tools/gen_metadata.py` generates the object, field, tab and layout metadata from it. The
object list (22: 21 custom objects + 1 hierarchy custom setting):

| Object | Purpose | Key relationships |
| --- | --- | --- |
| `CDO_Project__c` | A repository and its baseline. Owns the stages. `Auto_Merge__c` | — |
| `CDO_Environment__c` | An org: pipeline key, branch, GitHub Environment, `Health_Status__c` | Project (lookup) |
| `CDO_Stage__c` | A position in the chain: order, gate type, coverage floor | Project (master), Environment |
| `CDO_Release__c` | A bundle of work items that ship to production together | Project |
| `CDO_Work_Item__c` | The unit of change (`WI-0001`) | Project, Current Stage, Release |
| `CDO_Commit__c` | One commit | Work Item (master) |
| `CDO_Component__c` | One piece of metadata a work item carries | Work Item (master) |
| `CDO_Promotion__c` | A move from one stage to the next (`PRM-00001`) | Project, Source/Target Stage |
| `CDO_Promoted_Work_Item__c` | **Junction**: which work items a promotion carried | Promotion (master), Work Item |
| `CDO_Deployment__c` | One deploy attempt against one stage | Work Item, Promotion, Release, Stage, Environment |
| `CDO_Deployment_Step__c` | Pre / deploy / post work | Work Item, Deployment, Stage |
| `CDO_Approval__c` | An approval decision | Promotion, Work Item, Stage |
| `CDO_Scan_Finding__c` | A static-analysis finding | Work Item, Deployment |
| `CDO_Test_Script__c` | A manual test | Work Item, Stage |
| `CDO_Test_Result__c` | A manual test outcome | Test Script (master), Stage |
| `CDO_Audit_Event__c` | Append-only history (a validation rule blocks edits; no profile gets delete) | Work Item, Promotion, Deployment, Release |
| `CDO_Webhook__c` | Outbound notification target (Named Credential + path) | — |
| `CDO_Settings__c` | Hierarchy custom setting: GitHub owner/repo/ref/credential | — |
| `CDO_Component_Dependency__c` | Dependency edge between components | Component (master), Depends On |
| `CDO_Data_Set__c` | Records-not-metadata deployment set | Project, Source/Target Environment |
| `CDO_Data_Template__c` | One object's extraction rule in a data set | Data Set (master) |
| `CDO_Data_Relationship__c` | Parent/child link between templates | Data Set (master), Parent/Child Template |

**The junction matters more than it looks.** Write `CDO_Promoted_Work_Item__c` rows at
**every** promotion entry point: `CDOPromotionDispatcher.requestPromotion`, the entry-hop
promotion created on approval (callback `Deploy` with `environment` = entry and no promotion
id: create the promotion and its junction row first), and the bulk path. Without the junction,
`resolvePromotedWorkItems` returns early and the promotion stays `Deploying` forever.

**Seeded records** (`seed-pipeline.py`, from `pipeline.config.yml`) are upserted on external
ids, so re-running is safe: `CDO_Project__c.Key__c`, `CDO_Environment__c.Key__c`
(`<project>:<pipeline key>`) and `CDO_Stage__c.Key__c` (`<project>:<pipeline key>`).

**Percent fields** (`Coverage_Floor__c`, `Minimum_Coverage__c`, `Coverage_Percent__c`,
`Last_Coverage__c`, `Coverage_Threshold__c`) store literal percents when written through the API
or Apex (`85` means 85 %). Never give a Percent field a metadata `defaultValue`: `0.85` would be
needed there, and getting it wrong stores 8500 %.

---

## 4. Hub Apex services (the API the controllers call)

```apex
// GitHubService
public static DispatchResult dispatchWorkflow(String workflowFile, String gitRef, Map<String, String> inputs);
public class DispatchResult { public Boolean ok; public Integer statusCode; public String message; }
public static HttpResponse send(String method, String path, String body);   // relative to /repos/{owner}/{repo}
public static Boolean testConnection();                                      // GET /repos/{owner}/{repo}
public static String defaultRef();
public static String repoUrl();                                              // https://github.com/{owner}/{repo}

// CDO_Audit
public static void log(String eventType, String summary, String details, Map<String, Id> refs); // refs keys: workItem, promotion, deployment, release
public static void log(CDO_Audit_Event__c ev);

// CDO_WorkItemService
public static Id createWorkItem(CDO_Work_Item__c wi);           // defaults Project + Current Stage (none yet)
public static void requestCommit(Id workItemId, String componentsJson, String message);
public static String requestListChanges(Id workItemId, String sourceOrg);   // returns request id
public static void openPullRequest(Id workItemId);
public static void requestValidation(Id workItemId);           // these four throw WorkItemException when GitHub is not configured or dispatch is off
public static CDO_Stage__c nextStage(Id workItemId);             // null when already at production
public static void markBlocked(Set<Id> workItemIds, String reason);
public static String featureBranch(CDO_Work_Item__c wi);         // Feature_Branch__c or 'feature/' + Name

// CDOPromotionDispatcher — the real queue (a GitHub concurrency group is not a queue)
public static Id requestPromotion(List<Id> workItemIds, Id targetStageId, Map<String, String> options, Boolean dispatchNow);
    // options keys: testLevel, specifiedTests, checkOnly, allowDestructive, direction
    // creates CDO_Promotion__c (Queued, or Draft when dispatchNow=false) + junction rows + audit
public static void dispatchPromotion(Id promotionId);            // Draft → Queued, then dispatchNext
public static void dispatchNext(Id targetStageId);               // one in flight per target stage; oldest Queued first
public static void onPromotionFinished(Id promotionId);

// CDO_PromotionReconciler
public static void resolvePromotedWorkItems(Id promotionId);
public class ReconcileJob implements Schedulable { ... }   // schedule this (seed-pipeline.py does)
public class SweepJob implements Queueable, Database.AllowsCallouts { ... }  // the stuck-run sweep itself
public static void sweepNow();                                  // run a sweep immediately
// Salesforce refuses to enqueue a class that also implements Schedulable, so the scheduled job
// hands over to SweepJob.

// CDO_CallbackService
public static CDO_CallbackResource.CallbackResponse apply(CDO_CallbackResource.CallbackRequest req);
public static CDO_CallbackResource.CallbackResponse applyWorkItemEvent(CDO_CallbackResource.CallbackRequest req);

// CDO_NotificationService
public static void notify(String eventType, String summary, Map<String, Object> payload); // async, per active CDO_Webhook__c
```

Workflow file names and the Named Credential live in one place (`GitHubService` constants or
`CDO_Settings__c`), never scattered through controllers.

---

## 5. Data deploy plan (`sf-data-deploy.yml` input `plan`)

Base64 of:
```json
{ "dataSet": "Accounts with contacts",
  "templates": [ { "name": "Accounts", "object": "Account", "fields": ["Name","Industry"],
                   "filter": "Industry != null", "externalId": "External_Id__c", "order": 1, "limit": 200 } ],
  "relationships": [ { "parent": "Accounts", "child": "Contacts", "field": "AccountId" } ] }
```

---

## 6. Promotion branches and merges (pipeline side)

- A feature branch `feature/<WI>` is cut from the baseline branch.
- A promotion `promotion/<WI>-to-<env>` is cut from the target env branch, the feature is merged
  in, `delta(target_sha_at_cut..HEAD)` is deployed, and **only after** a successful deploy is the
  promotion merged into the target. The merge is refused if the target moved since the cut.
- **Merge mechanics.** The action first tries `git push origin HEAD:<target>`. If branch
  protection rejects the push, it falls back to opening a pull request `promotion/... → <target>`.
  It sets the `sfdevops/deploy` commit status on the promotion head and merges the PR pinned to
  that head SHA. Protection requires that status with "branches up to date" (strict). So GitHub
  itself refuses the merge if the target moved, and a feature PR's merge button can never be used:
  a feature head never carries `sfdevops/deploy`. If neither path merges, the job **fails**.
  It never reports success through a rejected push.
- When the promotion lands in the target, the feature PR's commits are on the base branch, and
  GitHub marks that PR merged. The PR was the review gate, never the merge path.
