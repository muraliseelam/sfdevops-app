/**
 * Work items from the UI: create (cdoNewWorkItem), read, list "my work", change status by hand,
 * and the source orgs a developer can commit from.
 *
 * Creation goes through CDO_WorkItemService.createWorkItem so the project and stage defaults
 * live in one place. Only an allow-list of fields can be set from the client.
 */
public with sharing class WorkItemController {

    /** Fields the create form may set (lower case for case-insensitive matching). */
    private static final Set<String> CREATABLE_FIELDS = new Set<String>{
        'subject__c', 'description__c', 'acceptance_criteria__c', 'story_points__c', 'project__c',
        'release__c', 'developer__c', 'source_org_alias__c', 'minimum_coverage__c',
        'specified_tests__c', 'test_level_override__c'
    };

    /** Statuses a person may set by hand. The rest are written by the pipeline. */
    private static final Set<String> MANUAL_STATUSES = new Set<String>{ 'New', 'In_Progress', 'Approved', 'Blocked', 'Cancelled' };

    @AuraEnabled
    public static Id createWorkItem(Map<String, Object> fields) {
        if (fields == null || fields.isEmpty()) {
            throw fail('Enter a subject for the work item.');
        }
        if (!Schema.SObjectType.CDO_Work_Item__c.isCreateable()) {
            throw fail('You do not have permission to create work items. Ask an admin for the CDO_Developer_Access permission set group.');
        }
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.CDO_Work_Item__c.fields.getMap();
        CDO_Work_Item__c wi = new CDO_Work_Item__c();
        for (String key : fields.keySet()) {
            if (key == null || !CREATABLE_FIELDS.contains(key.toLowerCase())) {
                throw fail('The field "' + key + '" cannot be set when creating a work item.');
            }
            Schema.DescribeFieldResult describe = fieldMap.get(key).getDescribe();
            try {
                wi.put(describe.getName(), coerce(describe.getType(), fields.get(key)));
            } catch (Exception e) {
                throw fail(describe.getLabel() + ' has an invalid value: ' + String.valueOf(fields.get(key)));
            }
        }
        if (String.isBlank(wi.Subject__c)) {
            throw fail('Enter a subject for the work item.');
        }
        if (wi.Developer__c == null) {
            wi.Developer__c = UserInfo.getUserId();
        }
        try {
            return CDO_WorkItemService.createWorkItem(wi);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw fail('Could not create the work item: ' + messageOf(e));
        }
    }

    @AuraEnabled(cacheable=true)
    public static CDO_Work_Item__c getWorkItem(Id workItemId) {
        if (workItemId == null) {
            return null;
        }
        List<CDO_Work_Item__c> rows = [
            SELECT Id, Name, Subject__c, Status__c, Description__c, Acceptance_Criteria__c, Story_Points__c,
                   Project__c, Project__r.Name, Current_Stage__c, Current_Stage__r.Name, Release__c, Release__r.Name,
                   Developer__c, Developer__r.Name, Feature_Branch__c, Source_Org_Alias__c, Merge_State__c,
                   Minimum_Coverage__c, Pull_Request_URL__c, Pull_Request_Number__c, Pull_Requests_Approved__c,
                   Review_State__c, Specified_Tests__c, Test_Level_Override__c, Last_Coverage__c,
                   Last_Tests_Passed__c, Last_Validation_Status__c, Last_Run_URL__c, Last_Commit_SHA__c,
                   Blocked_Reason__c, Conflict_Paths__c, Source_Changes_Status__c, Source_Changes_Received_On__c,
                   CreatedDate, LastModifiedDate
            FROM CDO_Work_Item__c
            WHERE Id = :workItemId
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /** Open work items the running user develops or created, most recently touched first. */
    @AuraEnabled(cacheable=true)
    public static List<CDO_Work_Item__c> getMyWorkItems() {
        Id me = UserInfo.getUserId();
        return [
            SELECT Id, Name, Subject__c, Status__c, Current_Stage__c, Current_Stage__r.Name, Release__r.Name,
                   Project__r.Name, Pull_Request_URL__c, Merge_State__c, Last_Validation_Status__c, LastModifiedDate
            FROM CDO_Work_Item__c
            WHERE (Developer__c = :me OR CreatedById = :me) AND Status__c NOT IN :PipelineController.CLOSED_WORK_ITEM
            ORDER BY LastModifiedDate DESC, Id DESC
            LIMIT 200
        ];
    }

    /**
     * Manual status change. Pipeline-owned statuses (Committed, In_Review, Promoting, Deployed,
     * Done) are refused. Approved makes a work item an entry-stage candidate, so it needs the
     * CDO_Approve_Entry permission.
     */
    @AuraEnabled
    public static CDO_Work_Item__c updateStatus(Id workItemId, String status) {
        if (workItemId == null || String.isBlank(status)) {
            throw fail('Choose a work item and a status.');
        }
        String target = status.trim().replace(' ', '_');
        if (!MANUAL_STATUSES.contains(target)) {
            throw fail('Status "' + status + '" is set by the pipeline, not by hand. You can choose New, In Progress, Approved, Blocked or Cancelled.');
        }
        if (target == 'Approved' && !GovernanceController.hasPermission(GovernanceController.PERM_APPROVE_ENTRY)) {
            throw fail('Approving a work item for the entry stage needs the ' + GovernanceController.PERM_APPROVE_ENTRY + ' permission.');
        }
        CDO_Work_Item__c current = getWorkItem(workItemId);
        if (current == null) {
            throw fail('That work item no longer exists or you do not have access to it.');
        }
        if (current.Status__c == target) {
            return current;
        }
        try {
            CDO_Work_Item__c upd = new CDO_Work_Item__c(Id = workItemId, Status__c = target);
            if (target != 'Blocked' && current.Status__c == 'Blocked') {
                upd.Blocked_Reason__c = null;
            }
            update upd;
            CDO_Audit.log(
                'Status',
                (current.Name + ' status ' + current.Status__c + ' → ' + target + ' by ' + UserInfo.getName()).abbreviate(255),
                null,
                new Map<String, Id>{ 'workItem' => workItemId }
            );
        } catch (Exception e) {
            throw fail('Could not change the status: ' + messageOf(e));
        }
        return getWorkItem(workItemId);
    }

    /** Developer source orgs (CDO_Environment__c with Type__c = 'Source'). */
    @AuraEnabled(cacheable=true)
    public static List<CDO_Environment__c> getSourceOrgs() {
        return [
            SELECT Id, Name, Pipeline_Key__c, Org_Alias__c, Branch__c, Project__c, Project__r.Name, Instance_URL__c
            FROM CDO_Environment__c
            WHERE Type__c = 'Source'
            ORDER BY Name
            LIMIT 200
        ];
    }

    // ----------------------------------------------------------------------------------------

    private static Object coerce(Schema.DisplayType fieldType, Object raw) {
        if (raw == null) {
            return null;
        }
        String s = String.valueOf(raw).trim();
        if (String.isBlank(s)) {
            return null;
        }
        switch on fieldType {
            // The allow-list holds only number, reference and text fields.
            when DOUBLE, PERCENT, CURRENCY, INTEGER, LONG {
                return Decimal.valueOf(s);
            }
            when REFERENCE, ID {
                return Id.valueOf(s);
            }
            when else {
                return s;
            }
        }
    }

    private static String messageOf(Exception e) {
        if (e instanceof DmlException) {
            return ((DmlException) e).getDmlMessage(0);
        }
        return e.getMessage();
    }

    private static AuraHandledException fail(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
