/**
 * Governance operations (cdoGovernance ops panel). Every method needs the CDO_Governance_Ops
 * custom permission, dispatches its ops workflow through GitHubService, and writes an audit event.
 *
 * The dispatch is sent before anything is written, so a refused dispatch leaves no record
 * claiming an operation started; the audit event records the request, and the workflow's own
 * callback records the outcome.
 */
public with sharing class GovernanceOpsController {

    private static final Pattern SHA_PATTERN = Pattern.compile('^[0-9a-fA-F]{7,40}$');

    /** Redeploy an environment at an earlier commit (sf-ops-rollback.yml). */
    @AuraEnabled
    public static String rollback(String targetEnv, String sha, String reason) {
        assertOps();
        String env = requirePipelineKey(targetEnv);
        if (String.isBlank(sha) || !SHA_PATTERN.matcher(sha.trim()).matches()) {
            throw fail('Enter the commit SHA to roll back to (7 to 40 hexadecimal characters).');
        }
        if (String.isBlank(reason)) {
            throw fail('Enter the reason for the rollback. It is kept in the audit log.');
        }
        String cleanSha = sha.trim().toLowerCase();
        IntegrationController.dispatchOrFail(GitHubService.WF_OPS_ROLLBACK, new Map<String, String>{
            'target_env' => env,
            'sha' => cleanSha,
            'test_level' => '',
            'reason' => reason.trim()
        });
        audit('Rollback', 'Rollback of ' + env + ' to ' + cleanSha.left(12) + ' requested by ' + UserInfo.getName(),
            'Reason: ' + reason.trim(), new Map<String, Id>());
        return 'Rollback of ' + env + ' to ' + cleanSha.left(12) + ' started.';
    }

    /** Redeploy a work item's feature to an environment (sf-ops-redeploy-feature.yml). */
    @AuraEnabled
    public static String redeployFeature(Id workItemId, String targetEnv) {
        assertOps();
        CDO_Work_Item__c wi = loadWorkItem(workItemId);
        String env = requirePipelineKey(targetEnv);
        String featureRef = CDO_WorkItemService.featureBranch(wi);
        IntegrationController.dispatchOrFail(GitHubService.WF_OPS_REDEPLOY, new Map<String, String>{
            'work_item' => wi.Name,
            'work_item_id' => wi.Id,
            'target_env' => env,
            'feature_ref' => featureRef
        });
        audit('Redeploy', 'Redeploy of ' + wi.Name + ' to ' + env + ' requested by ' + UserInfo.getName(),
            'Feature ref: ' + featureRef, new Map<String, Id>{ 'workItem' => wi.Id });
        return 'Redeploy of ' + wi.Name + ' to ' + env + ' started.';
    }

    /**
     * Recreate a work item's feature branch from the baseline with its tracked components
     * (sf-ops-recreate-feature.yml). paths: comma-separated component paths.
     */
    @AuraEnabled
    public static String recreateFeature(Id workItemId) {
        assertOps();
        CDO_Work_Item__c wi = loadWorkItem(workItemId);
        List<String> paths = new List<String>();
        for (CDO_Component__c c : [
            SELECT Path__c FROM CDO_Component__c
            WHERE Work_Item__c = :wi.Id AND Path__c != null AND Action__c != 'Delete'
            ORDER BY Path__c
        ]) {
            paths.add(c.Path__c);
        }
        if (paths.isEmpty()) {
            throw fail(wi.Name + ' has no tracked component paths to recreate the feature from. Commit components first.');
        }
        String branch = CDO_WorkItemService.featureBranch(wi);
        IntegrationController.dispatchOrFail(GitHubService.WF_OPS_RECREATE, new Map<String, String>{
            'work_item' => wi.Name,
            'work_item_id' => wi.Id,
            'feature_branch' => branch,
            'paths' => String.join(paths, ',')
        });
        audit('Recreate Feature', 'Recreate of ' + branch + ' for ' + wi.Name + ' requested by ' + UserInfo.getName(),
            paths.size() + ' path(s):\n' + String.join(paths, '\n'), new Map<String, Id>{ 'workItem' => wi.Id });
        return 'Recreating ' + branch + ' from ' + paths.size() + ' path' + (paths.size() == 1 ? '' : 's') + '.';
    }

    /** Re-align environment branches with what is deployed (sync-env-branches.yml). Blank = all. */
    @AuraEnabled
    public static String syncEnvBranches(String targetEnv) {
        assertOps();
        String env = String.isBlank(targetEnv) ? '' : requirePipelineKey(targetEnv);
        IntegrationController.dispatchOrFail(GitHubService.WF_SYNC_ENV, new Map<String, String>{
            'target_env' => env,
            'deploy' => 'false'
        });
        String scope = String.isBlank(env) ? 'all environment branches' : 'the ' + env + ' branch';
        audit('Sync', 'Sync of ' + scope + ' requested by ' + UserInfo.getName(), null, new Map<String, Id>());
        return 'Sync of ' + scope + ' started.';
    }

    /** Check in-flight work items for overlapping components (sf-conflict-check.yml). */
    @AuraEnabled
    public static String runConflictCheck() {
        assertOps();
        List<String> keys = new List<String>();
        for (CDO_Work_Item__c wi : [
            SELECT Name FROM CDO_Work_Item__c
            WHERE Status__c NOT IN ('New', 'Done', 'Cancelled')
                  AND Id IN (SELECT Work_Item__c FROM CDO_Component__c)
            ORDER BY Name
            LIMIT 500
        ]) {
            keys.add(wi.Name);
        }
        if (keys.size() < 2) {
            throw fail('A conflict check needs at least two in-flight work items with components. Found ' + keys.size() + '.');
        }
        IntegrationController.dispatchOrFail(GitHubService.WF_CONFLICT_CHECK, new Map<String, String>{
            'work_items' => String.join(keys, ',')
        });
        audit('Conflict', 'Conflict check of ' + keys.size() + ' work items requested by ' + UserInfo.getName(),
            String.join(keys, ', '), new Map<String, Id>());
        return 'Conflict check of ' + keys.size() + ' work items started. Overlaps are flagged on the components when it reports back.';
    }

    // ----------------------------------------------------------------------------------------

    private static void assertOps() {
        if (!GovernanceController.hasPermission(GovernanceController.PERM_GOVERNANCE_OPS)) {
            throw fail('Governance operations need the ' + GovernanceController.PERM_GOVERNANCE_OPS +
                ' permission (CDO_Admin_Access). Ask an admin to run this.');
        }
    }

    /** The pipeline key must name a stage or environment the hub knows. */
    private static String requirePipelineKey(String key) {
        if (String.isBlank(key)) {
            throw fail('Choose the target environment.');
        }
        String k = key.trim();
        Integer known = [SELECT COUNT() FROM CDO_Stage__c WHERE Pipeline_Key__c = :k] +
            [SELECT COUNT() FROM CDO_Environment__c WHERE Pipeline_Key__c = :k];
        if (known == 0) {
            throw fail('"' + k + '" is not a pipeline key the hub knows. Check pipeline.config.yml and re-run seed-pipeline.py.');
        }
        return k;
    }

    private static CDO_Work_Item__c loadWorkItem(Id workItemId) {
        List<CDO_Work_Item__c> rows = workItemId == null ? new List<CDO_Work_Item__c>() : [
            SELECT Id, Name, Feature_Branch__c, Status__c, Project__c, Current_Stage__c
            FROM CDO_Work_Item__c
            WHERE Id = :workItemId
        ];
        if (rows.isEmpty()) {
            throw fail('Choose an existing work item.');
        }
        return rows[0];
    }

    private static void audit(String eventType, String summary, String details, Map<String, Id> refs) {
        try {
            CDO_Audit.log(eventType, summary.abbreviate(255), details, refs);
        } catch (Exception e) {
            throw fail('The workflow was started, but the audit event could not be written: ' + e.getMessage());
        }
    }

    private static AuraHandledException fail(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
