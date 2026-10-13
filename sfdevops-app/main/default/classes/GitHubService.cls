/**
 * Outbound contract: hub -> GitHub `workflow_dispatch` (docs/CONTRACTS.md section 1).
 *
 * Every workflow file name and the Named Credential default live in this class and nowhere else.
 * A dispatch is a callout and a callout cannot follow DML in the same transaction, so callers that
 * have written records enqueue a {@link DispatchJob} instead of calling dispatchWorkflow directly.
 * Success is HTTP 204 and nothing else. A dispatch only proves that GitHub accepted the request:
 * only a callback writes the run URL, so no record is ever marked as running because of a dispatch.
 */
public with sharing class GitHubService {

    // ---- Workflow files (pipeline side: .github/workflows/*) -------------------------------------
    public static final String WF_COMMIT = 'sf-commit.yml';
    public static final String WF_LIST_CHANGES = 'sf-list-changes.yml';
    public static final String WF_OPEN_PR = 'sf-open-pr.yml';
    public static final String WF_PR_VALIDATION = 'sf-pr-validation.yml';
    public static final String WF_INT_DEPLOY = 'sf-int-deploy.yml';
    public static final String WF_PROMOTION = 'sf-promotion.yml';
    public static final String WF_PROMOTE = 'sf-promote.yml';
    public static final String WF_PROD_RELEASE = 'sf-prod-release.yml';
    public static final String WF_ASSEMBLE_RELEASE = 'assemble-release.yml';
    public static final String WF_AUTO_MERGE = 'auto-merge-approved.yml';
    public static final String WF_CONFLICT_CHECK = 'sf-conflict-check.yml';
    public static final String WF_DATA_DEPLOY = 'sf-data-deploy.yml';
    public static final String WF_OPS_ROLLBACK = 'sf-ops-rollback.yml';
    public static final String WF_OPS_REDEPLOY = 'sf-ops-redeploy-feature.yml';
    public static final String WF_OPS_RECREATE = 'sf-ops-recreate-feature.yml';
    public static final String WF_SYNC_ENV = 'sync-env-branches.yml';

    // ---- Connection defaults (overridden by CDO_Settings__c) -------------------------------------
    public static final String DEFAULT_NAMED_CREDENTIAL = 'GitHub_API';
    public static final String DEFAULT_REF = 'main';
    public static final String GITHUB_API_VERSION = '2022-11-28';
    public static final Integer DISPATCH_TIMEOUT_MS = 20000;
    public static final Integer SEND_TIMEOUT_MS = 30000;
    /** Callouts per DispatchJob execution; the rest chain into a follow-up job. */
    public static final Integer MAX_DISPATCHES_PER_JOB = 10;

    public class DispatchResult {
        @AuraEnabled public Boolean ok;
        @AuraEnabled public Integer statusCode;
        @AuraEnabled public String message;

        public DispatchResult() {
            this(false, 0, null);
        }

        public DispatchResult(Boolean ok, Integer statusCode, String message) {
            this.ok = ok;
            this.statusCode = statusCode;
            this.message = message;
        }
    }

    /** One workflow dispatch, optionally tied to the hub record that asked for it. */
    public class DispatchRequest {
        public String workflowFile;
        public String gitRef;
        public Map<String, String> inputs;
        public Id recordId;

        public DispatchRequest(String workflowFile, String gitRef, Map<String, String> inputs, Id recordId) {
            this.workflowFile = workflowFile;
            this.gitRef = gitRef;
            this.inputs = inputs;
            this.recordId = recordId;
        }
    }

    // ---- Settings ---------------------------------------------------------------------------------

    public static CDO_Settings__c settings() {
        CDO_Settings__c s = CDO_Settings__c.getOrgDefaults();
        return s == null ? new CDO_Settings__c() : s;
    }

    public static String namedCredential() {
        String nc = settings().Named_Credential__c;
        return String.isBlank(nc) ? DEFAULT_NAMED_CREDENTIAL : nc.trim();
    }

    public static String defaultRef() {
        String ref = settings().Workflow_Ref__c;
        return String.isBlank(ref) ? DEFAULT_REF : ref.trim();
    }

    /** True when the repository is named (owner and repo). Dispatch additionally needs Dispatch_Enabled__c. */
    public static Boolean isConfigured() {
        CDO_Settings__c s = settings();
        return String.isNotBlank(s.GitHub_Owner__c) && String.isNotBlank(s.GitHub_Repo__c);
    }

    /** Null when a workflow can be dispatched; otherwise the reason it cannot, worded for a person. */
    public static String configurationError() {
        if (!isConfigured()) {
            return 'GitHub is not configured: set GitHub Owner and GitHub Repo in SF DevOps Settings (CDO_Settings__c).';
        }
        if (settings().Dispatch_Enabled__c != true) {
            return 'Workflow dispatch is turned off: SF DevOps Settings > Dispatch Enabled is unchecked.';
        }
        return null;
    }

    public static String repoUrl() {
        if (!isConfigured()) {
            return null;
        }
        CDO_Settings__c s = settings();
        return 'https://github.com/' + s.GitHub_Owner__c.trim() + '/' + s.GitHub_Repo__c.trim();
    }

    // ---- Contract #1 ------------------------------------------------------------------------------

    /**
     * POST /repos/{owner}/{repo}/actions/workflows/{file}/dispatches. Never throws: a missing or
     * disabled configuration, a refused request and an unreachable GitHub all come back as ok=false.
     */
    public static DispatchResult dispatchWorkflow(String workflowFile, String gitRef, Map<String, String> inputs) {
        String configError = configurationError();
        if (configError != null) {
            return new DispatchResult(false, 0, configError);
        }
        if (String.isBlank(workflowFile)) {
            return new DispatchResult(false, 0, 'No workflow file was given.');
        }
        String file = workflowFile.trim();
        String ref = String.isBlank(gitRef) ? defaultRef() : gitRef.trim();
        String body = JSON.serialize(new Map<String, Object>{ 'ref' => ref, 'inputs' => stringInputs(inputs) });
        try {
            HttpResponse res = callout(
                'POST',
                '/actions/workflows/' + EncodingUtil.urlEncode(file, 'UTF-8') + '/dispatches',
                body,
                DISPATCH_TIMEOUT_MS
            );
            Integer code = res.getStatusCode();
            if (code == 204) {
                return new DispatchResult(true, 204, 'Dispatched ' + file + ' on ' + ref + '.');
            }
            return new DispatchResult(
                false,
                code,
                'GitHub refused ' + file + ' (HTTP ' + code + '): ' + abbreviate(res.getBody(), 500)
            );
        } catch (Exception e) {
            return new DispatchResult(false, 0, 'Could not reach GitHub to dispatch ' + file + ': ' + e.getMessage());
        }
    }

    /** Every dispatch input is a string: null becomes "", blank keys are dropped. */
    public static Map<String, String> stringInputs(Map<String, String> inputs) {
        Map<String, String> out = new Map<String, String>();
        if (inputs == null) {
            return out;
        }
        for (String key : inputs.keySet()) {
            if (String.isBlank(key)) {
                continue;
            }
            String value = inputs.get(key);
            out.put(key, value == null ? '' : value);
        }
        return out;
    }

    /**
     * Any GitHub REST call relative to /repos/{owner}/{repo}. Never throws: when GitHub is not
     * configured or cannot be reached, the response carries status code 0 and the reason in its body.
     */
    public static HttpResponse send(String method, String path, String body) {
        if (!isConfigured()) {
            return syntheticResponse(
                0,
                'GitHub is not configured: set GitHub Owner and GitHub Repo in SF DevOps Settings (CDO_Settings__c).'
            );
        }
        try {
            return callout(method, path, body, SEND_TIMEOUT_MS);
        } catch (Exception e) {
            return syntheticResponse(0, 'Could not reach GitHub: ' + e.getMessage());
        }
    }

    /** GET /repos/{owner}/{repo}: true only on HTTP 200. */
    public static Boolean testConnection() {
        HttpResponse res = send('GET', '', null);
        return res != null && res.getStatusCode() == 200;
    }

    private static HttpResponse callout(String method, String path, String body, Integer timeoutMs) {
        CDO_Settings__c s = settings();
        String suffix = String.isBlank(path) ? '' : path.trim();
        if (suffix.length() > 0 && !suffix.startsWith('/') && !suffix.startsWith('?')) {
            suffix = '/' + suffix;
        }
        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            'callout:' + namedCredential() + '/repos/' + s.GitHub_Owner__c.trim() + '/' + s.GitHub_Repo__c.trim() + suffix
        );
        req.setMethod(String.isBlank(method) ? 'GET' : method.trim().toUpperCase());
        req.setHeader('Accept', 'application/vnd.github+json');
        req.setHeader('X-GitHub-Api-Version', GITHUB_API_VERSION);
        req.setTimeout(timeoutMs);
        if (body != null) {
            req.setHeader('Content-Type', 'application/json');
            req.setBody(body);
        }
        return new Http().send(req);
    }

    private static HttpResponse syntheticResponse(Integer statusCode, String message) {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(statusCode);
        res.setStatus(abbreviate(message, 200));
        res.setBody(JSON.serialize(new Map<String, Object>{ 'message' => message }));
        return res;
    }

    private static String abbreviate(String value, Integer maxLength) {
        if (value == null) {
            return '';
        }
        return value.length() > maxLength ? value.abbreviate(maxLength) : value;
    }

    // ---- Async ------------------------------------------------------------------------------------

    /**
     * Enqueues a job when the transaction still has room for one. Returns null when it cannot: the
     * asynchronous job limit is used up, or an Apex test is already inside a queueable (tests cannot
     * chain queueables). Callers treat null as "not queued" and leave their records retryable.
     */
    public static Id enqueue(Queueable job) {
        if (job == null || Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return null;
        }
        if (Test.isRunningTest() && System.isQueueable()) {
            return null;
        }
        try {
            return System.enqueueJob(job);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'GitHubService.enqueue failed: ' + e.getMessage());
            return null;
        }
    }

    /**
     * Runs dispatches outside the transaction that asked for them, then records each outcome.
     *
     * without sharing, deliberately and narrowly: this job only stamps the outcome of a dispatch on
     * the record that requested it. It can run as the pipeline integration user (a dispatch chained
     * from a callback), who need not be able to see a developer's promotion or work item.
     */
    public without sharing class DispatchJob implements Queueable, Database.AllowsCallouts {
        public List<DispatchRequest> requests;
        /** Filled by run(); parallel to the requests processed in this execution. */
        public List<DispatchResult> results;

        public DispatchJob(String workflowFile, String gitRef, Map<String, String> inputs) {
            this(workflowFile, gitRef, inputs, null);
        }

        public DispatchJob(String workflowFile, String gitRef, Map<String, String> inputs, Id callbackRecordId) {
            this(new List<DispatchRequest>{ new DispatchRequest(workflowFile, gitRef, inputs, callbackRecordId) });
        }

        public DispatchJob(List<DispatchRequest> requests) {
            this.requests = requests == null ? new List<DispatchRequest>() : requests;
        }

        public void execute(QueueableContext context) {
            run();
        }

        public void run() {
            List<DispatchRequest> current = new List<DispatchRequest>();
            List<DispatchRequest> remaining = new List<DispatchRequest>();
            for (DispatchRequest r : requests) {
                if (r == null) {
                    continue;
                }
                if (current.size() < MAX_DISPATCHES_PER_JOB) {
                    current.add(r);
                } else {
                    remaining.add(r);
                }
            }
            // Every callout first: a callout cannot follow DML.
            results = new List<DispatchResult>();
            for (DispatchRequest r : current) {
                results.add(dispatchWorkflow(r.workflowFile, r.gitRef, r.inputs));
            }
            recordOutcomes(current, results);
            if (!remaining.isEmpty()) {
                enqueue(new DispatchJob(remaining));
            }
        }

        private void recordOutcomes(List<DispatchRequest> done, List<DispatchResult> outcomes) {
            Set<Id> promotionIds = new Set<Id>();
            Set<Id> workItemIds = new Set<Id>();
            Set<Id> releaseIds = new Set<Id>();
            Set<Id> dataSetIds = new Set<Id>();
            Set<Id> deploymentIds = new Set<Id>();
            for (Integer i = 0; i < done.size(); i++) {
                Id recordId = done[i].recordId;
                if (recordId == null || outcomes[i].ok) {
                    continue;
                }
                Schema.SObjectType t = recordId.getSObjectType();
                if (t == CDO_Promotion__c.SObjectType) {
                    promotionIds.add(recordId);
                } else if (t == CDO_Work_Item__c.SObjectType) {
                    workItemIds.add(recordId);
                } else if (t == CDO_Release__c.SObjectType) {
                    releaseIds.add(recordId);
                } else if (t == CDO_Data_Set__c.SObjectType) {
                    dataSetIds.add(recordId);
                } else if (t == CDO_Deployment__c.SObjectType) {
                    deploymentIds.add(recordId);
                }
            }
            Map<Id, CDO_Promotion__c> promotions = new Map<Id, CDO_Promotion__c>(
                [SELECT Id, Name, Status__c FROM CDO_Promotion__c WHERE Id IN :promotionIds]
            );
            Map<Id, CDO_Work_Item__c> workItems = new Map<Id, CDO_Work_Item__c>(
                [SELECT Id, Source_Changes_Status__c FROM CDO_Work_Item__c WHERE Id IN :workItemIds]
            );
            Map<Id, CDO_Release__c> releases = new Map<Id, CDO_Release__c>(
                [SELECT Id, Status__c FROM CDO_Release__c WHERE Id IN :releaseIds]
            );
            Map<Id, CDO_Data_Set__c> dataSets = new Map<Id, CDO_Data_Set__c>(
                [SELECT Id, Status__c FROM CDO_Data_Set__c WHERE Id IN :dataSetIds]
            );
            Map<Id, CDO_Deployment__c> deployments = new Map<Id, CDO_Deployment__c>(
                [SELECT Id, Status__c FROM CDO_Deployment__c WHERE Id IN :deploymentIds]
            );

            List<SObject> updates = new List<SObject>();
            List<CDO_Audit_Event__c> events = new List<CDO_Audit_Event__c>();
            Set<Id> finished = new Set<Id>();
            Datetime now = System.now();

            for (Integer i = 0; i < done.size(); i++) {
                DispatchRequest r = done[i];
                DispatchResult res = outcomes[i];
                Map<String, Id> refs = new Map<String, Id>();
                if (r.recordId != null) {
                    refs.put('record', r.recordId);
                }
                String details = JSON.serializePretty(
                    new Map<String, Object>{
                        'workflow' => r.workflowFile,
                        'ref' => String.isBlank(r.gitRef) ? defaultRef() : r.gitRef,
                        'inputs' => stringInputs(r.inputs),
                        'statusCode' => res.statusCode,
                        'message' => res.message
                    }
                );
                events.add(
                    CDO_Audit.build(
                        res.ok ? 'WorkflowDispatched' : 'WorkflowDispatchFailed',
                        res.ok ? r.workflowFile + ' dispatched.' : r.workflowFile + ' was not dispatched: ' + res.message,
                        details,
                        refs
                    )
                );
                if (res.ok || r.recordId == null) {
                    continue;
                }
                String reason = abbreviate(res.message, 32000);
                if (promotions.containsKey(r.recordId)) {
                    CDO_Promotion__c p = promotions.get(r.recordId);
                    if (p.Status__c != 'Queued' && p.Status__c != 'Dispatched') {
                        continue;
                    }
                    if (res.statusCode == 0) {
                        // Nothing reached GitHub: the promotion goes back in the queue untouched.
                        p.Status__c = 'Queued';
                        p.Dispatched_On__c = null;
                        p.Message__c = 'Not dispatched: ' + reason;
                    } else {
                        p.Status__c = 'Failed';
                        p.Completed_On__c = now;
                        p.Message__c = 'Dispatch refused by GitHub: ' + reason;
                        // A 422 is specific to this request, so the next promotion may still go.
                        // Auth or availability errors would fail the next one the same way, so the
                        // queue waits for the reconciler sweep instead of draining into failures.
                        if (res.statusCode == 422) {
                            finished.add(p.Id);
                        }
                    }
                    updates.add(p);
                } else if (workItems.containsKey(r.recordId)) {
                    CDO_Work_Item__c wi = workItems.get(r.recordId);
                    if (r.workflowFile == WF_LIST_CHANGES && wi.Source_Changes_Status__c == 'Requested') {
                        wi.Source_Changes_Status__c = 'Failed';
                        updates.add(wi);
                    }
                } else if (releases.containsKey(r.recordId)) {
                    CDO_Release__c rel = releases.get(r.recordId);
                    if (rel.Status__c == 'Assembling' || rel.Status__c == 'Validating' || rel.Status__c == 'Releasing') {
                        rel.Status__c = 'Failed';
                        updates.add(rel);
                    }
                } else if (dataSets.containsKey(r.recordId)) {
                    CDO_Data_Set__c ds = dataSets.get(r.recordId);
                    if (ds.Status__c == 'Deploying') {
                        ds.Status__c = 'Failed';
                        updates.add(ds);
                    }
                } else if (deployments.containsKey(r.recordId)) {
                    CDO_Deployment__c dep = deployments.get(r.recordId);
                    if (dep.Status__c == 'Running') {
                        dep.Status__c = 'Failed';
                        dep.Message__c = reason;
                        dep.Completed_On__c = now;
                        updates.add(dep);
                    }
                }
            }
            if (!updates.isEmpty()) {
                // Group by type so the mixed-type update stays within the DML chunk limit.
                Map<Schema.SObjectType, List<SObject>> byType = new Map<Schema.SObjectType, List<SObject>>();
                for (SObject record : updates) {
                    Schema.SObjectType t = record.getSObjectType();
                    if (!byType.containsKey(t)) {
                        byType.put(t, new List<SObject>());
                    }
                    byType.get(t).add(record);
                }
                List<SObject> grouped = new List<SObject>();
                for (List<SObject> records : byType.values()) {
                    grouped.addAll(records);
                }
                for (Database.SaveResult sr : Database.update(grouped, false)) {
                    if (!sr.isSuccess()) {
                        System.debug(LoggingLevel.ERROR, 'DispatchJob could not stamp ' + sr.getId() + ': ' + sr.getErrors());
                    }
                }
            }
            CDO_Audit.log(events);
            if (!finished.isEmpty()) {
                CDOPromotionDispatcher.beginDeferral();
                try {
                    for (Id promotionId : finished) {
                        CDOPromotionDispatcher.onPromotionFinished(promotionId);
                    }
                } finally {
                    CDOPromotionDispatcher.endDeferral();
                }
            }
        }
    }
}
