/**
 * Work item operations the UI controllers call (docs/CONTRACTS.md section 4).
 *
 * Every GitHub action is dispatched through GitHubService.DispatchJob, so it is safe to call after
 * DML. A request that cannot be dispatched at all (GitHub not configured, dispatch turned off) fails
 * fast with a WorkItemException the UI can show, instead of leaving a silent audit row.
 *
 * inherited sharing: controllers call this class with sharing, and the callback path
 * (CDO_CallbackService, reached through the REST resources' system-context hop) calls markBlocked
 * and featureBranch for records the pipeline integration user cannot necessarily see.
 */
public inherited sharing class CDO_WorkItemService {

    public class WorkItemException extends Exception {}

    public static final String FEATURE_PREFIX = 'feature/';
    public static final Set<String> CLOSED_STATUSES = new Set<String>{ 'Done', 'Cancelled' };
    private static final Integer PR_BODY_MAX = 8000;

    /** Inserts a work item. Defaults: Project (settings default project, or the only active one), Status New. No stage yet. */
    public static Id createWorkItem(CDO_Work_Item__c wi) {
        if (wi == null) {
            throw new WorkItemException('A work item is required.');
        }
        if (wi.Id != null) {
            throw new WorkItemException('This work item already exists.');
        }
        if (String.isBlank(wi.Subject__c)) {
            throw new WorkItemException('A subject is required.');
        }
        if (wi.Project__c == null) {
            wi.Project__c = defaultProjectId();
        }
        // Current_Stage__c stays empty: a work item enters the chain with its first (entry-hop) promotion.
        if (String.isBlank(wi.Status__c)) {
            wi.Status__c = 'New';
        }
        insert wi;
        CDO_Audit.log(
            'WorkItemCreated',
            'Work item created: ' + wi.Subject__c,
            null,
            new Map<String, Id>{ 'workItem' => wi.Id }
        );
        return wi.Id;
    }

    /** Dispatches sf-commit.yml with the selected components ([{"type":"ApexClass","name":"Foo"}]). */
    public static void requestCommit(Id workItemId, String componentsJson, String message) {
        CDO_Work_Item__c wi = getWorkItem(workItemId);
        assertOpen(wi);
        String components = normalizeComponents(componentsJson);
        String commitMessage = String.isBlank(message) ? wi.Name + ': ' + wi.Subject__c : message.trim();
        dispatch(
            GitHubService.WF_COMMIT,
            new Map<String, String>{
                'work_item' => wi.Name,
                'work_item_id' => String.valueOf(wi.Id),
                'source_org' => nvl(wi.Source_Org_Alias__c),
                'components' => components,
                'commit_message' => commitMessage,
                'feature_branch' => featureBranch(wi)
            },
            wi.Id
        );
        CDO_Audit.log(
            'CommitRequested',
            'Commit requested for ' + wi.Name + ' on ' + featureBranch(wi),
            components,
            new Map<String, Id>{ 'workItem' => wi.Id }
        );
    }

    /** Dispatches sf-list-changes.yml and returns the request id the callback will echo. */
    public static String requestListChanges(Id workItemId, String sourceOrg) {
        CDO_Work_Item__c wi = getWorkItem(workItemId);
        assertOpen(wi);
        assertDispatchable();
        String requestId = UUID.randomUUID().toString();
        String org = String.isNotBlank(sourceOrg) ? sourceOrg.trim() : nvl(wi.Source_Org_Alias__c);
        update new CDO_Work_Item__c(Id = wi.Id, Source_Changes_Status__c = 'Requested');
        dispatch(
            GitHubService.WF_LIST_CHANGES,
            new Map<String, String>{
                'work_item' => wi.Name,
                'work_item_id' => String.valueOf(wi.Id),
                'source_org' => org,
                'request_id' => requestId
            },
            wi.Id
        );
        CDO_Audit.log(
            'ListChangesRequested',
            'Source changes requested for ' + wi.Name + (String.isBlank(org) ? '' : ' from ' + org),
            'request_id: ' + requestId,
            new Map<String, Id>{ 'workItem' => wi.Id }
        );
        return requestId;
    }

    /** Dispatches sf-open-pr.yml for the work item's feature branch. */
    public static void openPullRequest(Id workItemId) {
        CDO_Work_Item__c wi = getWorkItem(workItemId);
        assertOpen(wi);
        List<String> body = new List<String>();
        if (String.isNotBlank(wi.Description__c)) {
            body.add(wi.Description__c);
        }
        if (String.isNotBlank(wi.Acceptance_Criteria__c)) {
            body.add('Acceptance criteria:\n' + wi.Acceptance_Criteria__c);
        }
        body.add('Work item: ' + wi.Name + ' (' + URL.getOrgDomainUrl().toExternalForm() + '/' + wi.Id + ')');
        String text = String.join(body, '\n\n');
        dispatch(
            GitHubService.WF_OPEN_PR,
            new Map<String, String>{
                'work_item' => wi.Name,
                'work_item_id' => String.valueOf(wi.Id),
                'feature_branch' => featureBranch(wi),
                'title' => wi.Name + ': ' + wi.Subject__c,
                'body' => text.length() > PR_BODY_MAX ? text.abbreviate(PR_BODY_MAX) : text
            },
            wi.Id
        );
        CDO_Audit.log(
            'PullRequestRequested',
            'Pull request requested for ' + wi.Name + ' from ' + featureBranch(wi),
            null,
            new Map<String, Id>{ 'workItem' => wi.Id }
        );
    }

    /** Dispatches sf-pr-validation.yml for the work item's pull request. */
    public static void requestValidation(Id workItemId) {
        CDO_Work_Item__c wi = getWorkItem(workItemId);
        assertOpen(wi);
        if (wi.Pull_Request_Number__c == null) {
            throw new WorkItemException(wi.Name + ' has no pull request yet. Open one before validating.');
        }
        String prNumber = String.valueOf(wi.Pull_Request_Number__c.intValue());
        dispatch(
            GitHubService.WF_PR_VALIDATION,
            new Map<String, String>{
                'pr_number' => prNumber,
                'work_item' => wi.Name,
                'work_item_id' => String.valueOf(wi.Id)
            },
            wi.Id
        );
        CDO_Audit.log(
            'ValidationRequested',
            'Validation requested for ' + wi.Name + ' (pull request #' + prNumber + ')',
            null,
            new Map<String, Id>{ 'workItem' => wi.Id }
        );
    }

    /** The next stage by Order__c within the work item's project; the entry stage when it has none; null at production. */
    public static CDO_Stage__c nextStage(Id workItemId) {
        CDO_Work_Item__c wi = getWorkItem(workItemId);
        if (wi.Project__c == null) {
            return null;
        }
        return nextStageFrom(orderedStages(wi.Project__c), wi.Current_Stage__c);
    }

    /** Status Blocked plus the reason, for every open work item in the set. */
    public static void markBlocked(Set<Id> workItemIds, String reason) {
        if (workItemIds == null || workItemIds.isEmpty()) {
            return;
        }
        String text = String.isBlank(reason) ? 'Blocked.' : reason.trim();
        if (text.length() > 32768) {
            text = text.abbreviate(32768);
        }
        List<CDO_Work_Item__c> updates = new List<CDO_Work_Item__c>();
        List<CDO_Audit_Event__c> events = new List<CDO_Audit_Event__c>();
        for (CDO_Work_Item__c wi : [SELECT Id, Name, Status__c FROM CDO_Work_Item__c WHERE Id IN :workItemIds]) {
            if (CLOSED_STATUSES.contains(wi.Status__c)) {
                continue;
            }
            updates.add(new CDO_Work_Item__c(Id = wi.Id, Status__c = 'Blocked', Blocked_Reason__c = text));
            events.add(CDO_Audit.build('WorkItemBlocked', wi.Name + ' blocked: ' + text, text, new Map<String, Id>{ 'workItem' => wi.Id }));
        }
        update updates;
        CDO_Audit.log(events);
    }

    /** Feature_Branch__c, or 'feature/' + Name. */
    public static String featureBranch(CDO_Work_Item__c wi) {
        if (wi == null) {
            return null;
        }
        if (String.isNotBlank(wi.Feature_Branch__c)) {
            return wi.Feature_Branch__c.trim();
        }
        return String.isBlank(wi.Name) ? null : FEATURE_PREFIX + wi.Name;
    }

    // ---- Helpers shared with the dispatcher, the callbacks and the command center ---------------

    public static CDO_Work_Item__c getWorkItem(Id workItemId) {
        if (workItemId == null) {
            throw new WorkItemException('A work item id is required.');
        }
        List<CDO_Work_Item__c> rows = [
            SELECT Id, Name, Subject__c, Status__c, Project__c, Current_Stage__c, Release__c,
                Feature_Branch__c, Source_Org_Alias__c, Merge_State__c, Pull_Request_URL__c,
                Pull_Request_Number__c, Pull_Requests_Approved__c, Review_State__c, Description__c,
                Acceptance_Criteria__c, Specified_Tests__c, Test_Level_Override__c, Last_Commit_SHA__c,
                Last_Validation_Status__c, Minimum_Coverage__c, Last_Coverage__c
            FROM CDO_Work_Item__c
            WHERE Id = :workItemId
        ];
        if (rows.isEmpty()) {
            throw new WorkItemException('Work item ' + workItemId + ' was not found or is not visible to you.');
        }
        return rows[0];
    }

    /** CDO_Settings__c.Default_Project_Key__c, else the only active project, else null. */
    public static Id defaultProjectId() {
        String key = GitHubService.settings().Default_Project_Key__c;
        if (String.isNotBlank(key)) {
            List<CDO_Project__c> byKey = [SELECT Id FROM CDO_Project__c WHERE Key__c = :key.trim() LIMIT 1];
            if (!byKey.isEmpty()) {
                return byKey[0].Id;
            }
        }
        List<CDO_Project__c> active = [SELECT Id FROM CDO_Project__c WHERE Active__c = true ORDER BY CreatedDate ASC, Id ASC LIMIT 2];
        return active.size() == 1 ? active[0].Id : null;
    }

    /** The project's stages in promotion order (Order__c, then Id). */
    public static List<CDO_Stage__c> orderedStages(Id projectId) {
        if (projectId == null) {
            return new List<CDO_Stage__c>();
        }
        return [
            SELECT Id, Name, Project__c, Environment__c, Environment__r.Name, Environment__r.Health_Status__c,
                Order__c, Gate_Type__c, Coverage_Floor__c, Is_Entry__c, Is_Production__c, Branch__c,
                Pipeline_Key__c, Test_Level__c
            FROM CDO_Stage__c
            WHERE Project__c = :projectId
            ORDER BY Order__c ASC NULLS LAST, Id ASC
        ];
    }

    /** The stage after currentStageId in an ordered list; the entry stage when there is no current stage; null at production. */
    public static CDO_Stage__c nextStageFrom(List<CDO_Stage__c> ordered, Id currentStageId) {
        if (ordered == null || ordered.isEmpty()) {
            return null;
        }
        if (currentStageId == null) {
            for (CDO_Stage__c s : ordered) {
                if (s.Is_Entry__c == true) {
                    return s;
                }
            }
            for (CDO_Stage__c s : ordered) {
                if (s.Is_Production__c != true) {
                    return s;
                }
            }
            return ordered[0];
        }
        for (Integer i = 0; i < ordered.size(); i++) {
            if (ordered[i].Id == currentStageId) {
                if (ordered[i].Is_Production__c == true) {
                    return null;
                }
                return i + 1 < ordered.size() ? ordered[i + 1] : null;
            }
        }
        return null;
    }

    /** Reduces a component selection to the sf-commit.yml shape [{"type":..,"name":..}], de-duplicated. */
    public static String normalizeComponents(String componentsJson) {
        if (String.isBlank(componentsJson)) {
            throw new WorkItemException('Select at least one component to commit.');
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(componentsJson);
        } catch (Exception e) {
            throw new WorkItemException('Components must be a JSON array of {"type","name"} objects.');
        }
        if (!(parsed instanceof List<Object>)) {
            throw new WorkItemException('Components must be a JSON array of {"type","name"} objects.');
        }
        // Written field by field so the payload reads exactly like the contract: {"type":..,"name":..}.
        JSONGenerator out = JSON.createGenerator(false);
        out.writeStartArray();
        Integer count = 0;
        Set<String> seen = new Set<String>();
        for (Object item : (List<Object>) parsed) {
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> m = (Map<String, Object>) item;
            String mdType = firstText(m, new List<String>{ 'type', 'metadataType', 'Metadata_Type__c' });
            String name = firstText(m, new List<String>{ 'name', 'fullName', 'memberName', 'Member_Name__c' });
            if (mdType == null || name == null) {
                continue;
            }
            String key = (mdType + ':' + name).toLowerCase();
            if (seen.add(key)) {
                out.writeStartObject();
                out.writeStringField('type', mdType);
                out.writeStringField('name', name);
                out.writeEndObject();
                count++;
            }
        }
        if (count == 0) {
            throw new WorkItemException('Select at least one component to commit.');
        }
        out.writeEndArray();
        return out.getAsString();
    }

    private static String firstText(Map<String, Object> m, List<String> keys) {
        for (String k : keys) {
            Object v = m.get(k);
            if (v != null && String.isNotBlank(String.valueOf(v))) {
                return String.valueOf(v).trim();
            }
        }
        return null;
    }

    private static void assertOpen(CDO_Work_Item__c wi) {
        if (CLOSED_STATUSES.contains(wi.Status__c)) {
            throw new WorkItemException(wi.Name + ' is ' + wi.Status__c + '.');
        }
    }

    private static void assertDispatchable() {
        String configError = GitHubService.configurationError();
        if (configError != null) {
            throw new WorkItemException(configError);
        }
    }

    private static void dispatch(String workflowFile, Map<String, String> inputs, Id recordId) {
        assertDispatchable();
        Id jobId = GitHubService.enqueue(
            new GitHubService.DispatchJob(workflowFile, GitHubService.defaultRef(), inputs, recordId)
        );
        if (jobId == null) {
            throw new WorkItemException(
                workflowFile + ' could not be queued: this transaction has used its asynchronous job limit. Try again.'
            );
        }
    }

    private static String nvl(String value) {
        return value == null ? '' : value;
    }
}
