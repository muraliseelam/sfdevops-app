/**
 * Git actions for a work item (cdoCommit, cdoWorkItemCommandCenter): list a source org's changes,
 * commit selected components, open the pull request, validate, and read the commit history.
 *
 * Every action delegates to CDO_WorkItemService, which records the intent and dispatches the
 * workflow from a Queueable. A requested action is not a started run: only the workflow's
 * callback writes the run URL and the results.
 */
public with sharing class GitController {

    private static final Integer MAX_COMPONENTS = 5000;

    /** Ask the source org for its changed metadata (sf-list-changes.yml). Returns the request id. */
    @AuraEnabled
    public static String requestListChanges(Id workItemId, String sourceOrg) {
        CDO_Work_Item__c wi = loadWorkItem(workItemId);
        String org = String.isNotBlank(sourceOrg) ? sourceOrg.trim() : wi.Source_Org_Alias__c;
        if (String.isBlank(org)) {
            throw fail('Choose the source org to list changes from.');
        }
        try {
            if (org != wi.Source_Org_Alias__c) {
                // The commit workflow reads the source org from the work item, so remember the choice.
                update new CDO_Work_Item__c(Id = wi.Id, Source_Org_Alias__c = org.abbreviate(80));
            }
            return CDO_WorkItemService.requestListChanges(wi.Id, org);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw fail('Could not request the list of changes: ' + messageOf(e));
        }
    }

    /**
     * The change list the workflow stored on the work item, newest first. Not cacheable on
     * purpose: the commit screen polls it until the callback arrives.
     */
    @AuraEnabled
    public static ListChangesView getListChanges(Id workItemId) {
        CDO_Work_Item__c wi = loadWorkItem(workItemId);
        ListChangesView view = new ListChangesView();
        view.workItemName = wi.Name;
        view.status = String.isBlank(wi.Source_Changes_Status__c) ? 'Idle' : wi.Source_Changes_Status__c;
        view.receivedOn = wi.Source_Changes_Received_On__c;
        view.sourceOrg = wi.Source_Org_Alias__c;

        Set<String> committed = new Set<String>();
        for (CDO_Component__c c : [SELECT Unique_ID__c FROM CDO_Component__c WHERE Work_Item__c = :wi.Id AND Unique_ID__c != null]) {
            committed.add(c.Unique_ID__c);
        }

        if (String.isNotBlank(wi.Source_Changes_JSON__c)) {
            try {
                Object parsed = JSON.deserializeUntyped(wi.Source_Changes_JSON__c);
                List<Object> members;
                if (parsed instanceof List<Object>) {
                    members = (List<Object>) parsed;
                } else if (parsed instanceof Map<String, Object>) {
                    Map<String, Object> envelope = (Map<String, Object>) parsed;
                    members = (List<Object>) envelope.get('members');
                    if (envelope.get('message') != null) {
                        view.message = String.valueOf(envelope.get('message'));
                    }
                    if (envelope.get('sourceOrg') != null) {
                        view.sourceOrg = String.valueOf(envelope.get('sourceOrg'));
                    }
                }
                if (members != null) {
                    for (Object o : members) {
                        if (o instanceof Map<String, Object>) {
                            SourceMember m = new SourceMember((Map<String, Object>) o);
                            if (String.isNotBlank(m.type) && String.isNotBlank(m.name)) {
                                m.alreadyCommitted = committed.contains(m.key);
                                view.members.add(m);
                            }
                        }
                    }
                }
                view.members.sort();
            } catch (Exception e) {
                view.message = 'The stored change list could not be read (' + e.getMessage() + '). List changes again.';
            }
        }
        view.total = view.members.size();
        return view;
    }

    /**
     * Commit the chosen components (sf-commit.yml). componentsJson: [{"type":"ApexClass","name":"Foo"}].
     */
    @AuraEnabled
    public static String commitComponents(Id workItemId, String componentsJson, String message) {
        CDO_Work_Item__c wi = loadWorkItem(workItemId);
        if (String.isBlank(message)) {
            throw fail('Enter a commit message.');
        }
        String normalized = normalizeComponents(componentsJson);
        try {
            CDO_WorkItemService.requestCommit(wi.Id, normalized, message.trim());
            Integer count = ((List<Object>) JSON.deserializeUntyped(normalized)).size();
            return 'Commit of ' + count + ' component' + (count == 1 ? '' : 's') + ' requested for ' + wi.Name +
                '. The commit appears here when the workflow reports back.';
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw fail('Could not request the commit: ' + messageOf(e));
        }
    }

    /** Open the feature pull request (sf-open-pr.yml). Needs at least one commit. */
    @AuraEnabled
    public static String openPullRequest(Id workItemId) {
        CDO_Work_Item__c wi = loadWorkItem(workItemId);
        if (String.isNotBlank(wi.Pull_Request_URL__c)) {
            throw fail(wi.Name + ' already has a pull request: ' + wi.Pull_Request_URL__c);
        }
        if (String.isBlank(wi.Last_Commit_SHA__c) && !hasCommits(wi.Id)) {
            throw fail('Commit components to ' + wi.Name + ' before opening a pull request.');
        }
        try {
            CDO_WorkItemService.openPullRequest(wi.Id);
            return 'Pull request requested for ' + wi.Name + '.';
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw fail('Could not request the pull request: ' + messageOf(e));
        }
    }

    /** Run a check-only validation of the work item's changes (sf-pr-validation.yml). */
    @AuraEnabled
    public static String requestValidation(Id workItemId) {
        CDO_Work_Item__c wi = loadWorkItem(workItemId);
        if (String.isBlank(wi.Last_Commit_SHA__c) && !hasCommits(wi.Id)) {
            throw fail('Commit components to ' + wi.Name + ' before validating.');
        }
        if (wi.Last_Validation_Status__c == 'Running') {
            throw fail('A validation of ' + wi.Name + ' is already running' +
                (String.isBlank(wi.Last_Run_URL__c) ? '.' : ': ' + wi.Last_Run_URL__c));
        }
        try {
            CDO_WorkItemService.requestValidation(wi.Id);
            return 'Validation requested for ' + wi.Name + '.';
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw fail('Could not request the validation: ' + messageOf(e));
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<CDO_Commit__c> getCommits(Id workItemId) {
        if (workItemId == null) {
            return new List<CDO_Commit__c>();
        }
        return [
            SELECT Id, Name, SHA__c, Branch__c, Message__c, Component_Count__c, Workflow_Run_URL__c,
                   Committed_By__c, Committed_On__c, CreatedDate
            FROM CDO_Commit__c
            WHERE Work_Item__c = :workItemId
            ORDER BY Committed_On__c DESC NULLS LAST, CreatedDate DESC, Id DESC
            LIMIT 200
        ];
    }

    // ----------------------------------------------------------------------------------------

    /** Validates and de-duplicates the component list; returns canonical JSON. */
    @TestVisible
    private static String normalizeComponents(String componentsJson) {
        if (String.isBlank(componentsJson)) {
            throw fail('Select at least one component to commit.');
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(componentsJson);
        } catch (Exception e) {
            throw fail('The component list is not valid JSON.');
        }
        if (!(parsed instanceof List<Object>) || ((List<Object>) parsed).isEmpty()) {
            throw fail('Select at least one component to commit.');
        }
        List<Object> items = (List<Object>) parsed;
        if (items.size() > MAX_COMPONENTS) {
            throw fail('Commit at most ' + MAX_COMPONENTS + ' components at a time.');
        }
        Set<String> seen = new Set<String>();
        JSONGenerator gen = JSON.createGenerator(false);
        gen.writeStartArray();
        for (Object o : items) {
            Map<String, Object> m = o instanceof Map<String, Object> ? (Map<String, Object>) o : null;
            String type = m == null || m.get('type') == null ? null : String.valueOf(m.get('type')).trim();
            String name = m == null || m.get('name') == null ? null : String.valueOf(m.get('name')).trim();
            if (String.isBlank(type) || String.isBlank(name)) {
                throw fail('Every component needs a type and a name, for example {"type":"ApexClass","name":"Foo"}.');
            }
            if (seen.add(type + ':' + name)) {
                gen.writeStartObject();
                gen.writeStringField('type', type);
                gen.writeStringField('name', name);
                gen.writeEndObject();
            }
        }
        gen.writeEndArray();
        return gen.getAsString();
    }

    private static Boolean hasCommits(Id workItemId) {
        return ![SELECT Id FROM CDO_Commit__c WHERE Work_Item__c = :workItemId LIMIT 1].isEmpty();
    }

    private static CDO_Work_Item__c loadWorkItem(Id workItemId) {
        List<CDO_Work_Item__c> rows = workItemId == null ? new List<CDO_Work_Item__c>() : [
            SELECT Id, Name, Status__c, Source_Org_Alias__c, Source_Changes_JSON__c, Source_Changes_Status__c,
                   Source_Changes_Received_On__c, Pull_Request_URL__c, Pull_Request_Number__c, Last_Commit_SHA__c,
                   Last_Validation_Status__c, Last_Run_URL__c, Feature_Branch__c
            FROM CDO_Work_Item__c
            WHERE Id = :workItemId
        ];
        if (rows.isEmpty()) {
            throw fail('That work item no longer exists or you do not have access to it.');
        }
        return rows[0];
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

    // ----------------------------------------------------------------------------------------

    public class ListChangesView {
        @AuraEnabled public String workItemName;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime receivedOn;
        @AuraEnabled public String sourceOrg;
        @AuraEnabled public String message;
        @AuraEnabled public Integer total = 0;
        @AuraEnabled public List<SourceMember> members = new List<SourceMember>();
    }

    /** One changed member reported by the source org. Sorts newest first. */
    public class SourceMember implements Comparable {
        @AuraEnabled public String key;
        @AuraEnabled public String type;
        @AuraEnabled public String name;
        @AuraEnabled public String lastModifiedDate;
        @AuraEnabled public String lastModifiedBy;
        @AuraEnabled public String state;
        @AuraEnabled public Boolean alreadyCommitted = false;

        public SourceMember(Map<String, Object> m) {
            type = str(m.get('type'));
            name = str(m.get('name'));
            lastModifiedDate = str(m.get('lastModifiedDate'));
            lastModifiedBy = str(m.get('lastModifiedBy'));
            state = str(m.get('state'));
            key = type + ':' + name;
        }

        public Integer compareTo(Object other) {
            SourceMember o = (SourceMember) other;
            String a = lastModifiedDate == null ? '' : lastModifiedDate;
            String b = o.lastModifiedDate == null ? '' : o.lastModifiedDate;
            if (a != b) {
                // ISO-8601 strings sort chronologically; reverse for newest first.
                return a > b ? -1 : 1;
            }
            return key == o.key ? 0 : (key < o.key ? -1 : 1);
        }

        private String str(Object o) {
            return o == null ? null : String.valueOf(o);
        }
    }
}
