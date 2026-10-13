/**
 * Releases for cdoReleaseBoard: list and create releases, add and remove work items, assemble the
 * release branch (assemble-release.yml) and start the production release (sf-prod-release.yml).
 *
 * The production release validates in prod-validate first and then waits on the GitHub
 * Environment's required reviewer, so starting it needs CDO_Run_Prod_Release but does not
 * by itself deploy anything.
 */
public with sharing class ReleaseController {

    private static final Set<String> LOCKED_STATUSES = new Set<String>{ 'Validating', 'Releasing', 'Released', 'Cancelled' };
    private static final Set<String> ASSEMBLE_FROM = new Set<String>{ 'Planned', 'Ready', 'Failed' };
    private static final Set<String> RELEASE_FROM = new Set<String>{ 'Ready', 'Failed' };

    @AuraEnabled(cacheable=true)
    public static List<ReleaseView> getReleases(Id projectId) {
        List<ReleaseView> views = new List<ReleaseView>();
        String soql =
            'SELECT Id, Name, Status__c, Project__c, Project__r.Name, Version__c, Target_Date__c, Released_On__c, ' +
            'Release_Branch__c, Tag__c, Release_URL__c, Workflow_Run_URL__c, Validated_Deploy_Id__c, Notes__c, CreatedDate, ' +
            '(SELECT Id, Name, Subject__c, Status__c, Current_Stage__r.Name, Current_Stage__r.Is_Production__c, ' +
            'Developer__r.Name, Pull_Request_URL__c, Merge_State__c FROM Work_Items__r ORDER BY Name LIMIT 500) ' +
            'FROM CDO_Release__c' +
            (projectId == null ? '' : ' WHERE Project__c = :projectId') +
            ' ORDER BY Target_Date__c ASC NULLS LAST, CreatedDate DESC, Id DESC LIMIT 200';
        for (CDO_Release__c r : (List<CDO_Release__c>) Database.queryWithBinds(
                soql, new Map<String, Object>{ 'projectId' => projectId }, AccessLevel.SYSTEM_MODE)) {
            views.add(new ReleaseView(r));
        }
        return views;
    }

    /** Open work items of the project that are not in any release, for the "add work items" picker. */
    @AuraEnabled(cacheable=true)
    public static List<CDO_Work_Item__c> getAvailableWorkItems(Id projectId) {
        CDO_Project__c project = PipelineController.resolveProject(projectId);
        if (project == null) {
            return new List<CDO_Work_Item__c>();
        }
        Id pid = project.Id;
        return [
            SELECT Id, Name, Subject__c, Status__c, Current_Stage__r.Name, Developer__r.Name
            FROM CDO_Work_Item__c
            WHERE Project__c = :pid AND Release__c = null AND Status__c NOT IN :PipelineController.CLOSED_WORK_ITEM
            ORDER BY Name
            LIMIT 1000
        ];
    }

    @AuraEnabled
    public static Id createRelease(String name, Id projectId, Date targetDate) {
        if (String.isBlank(name)) {
            throw fail('Enter a release name.');
        }
        CDO_Project__c project = PipelineController.resolveProject(projectId);
        if (project == null) {
            throw fail('There is no project to create the release in. Run seed-pipeline.py first.');
        }
        try {
            CDO_Release__c r = new CDO_Release__c(
                Name = name.trim().abbreviate(80),
                Project__c = project.Id,
                Target_Date__c = targetDate,
                Status__c = 'Planned'
            );
            insert r;
            CDO_Audit.log('Release', ('Release ' + r.Name + ' created by ' + UserInfo.getName()).abbreviate(255), null,
                new Map<String, Id>{ 'release' => r.Id });
            return r.Id;
        } catch (Exception e) {
            throw fail('Could not create the release: ' + messageOf(e));
        }
    }

    @AuraEnabled
    public static Integer addWorkItems(Id releaseId, List<Id> workItemIds) {
        if (workItemIds == null || workItemIds.isEmpty()) {
            throw fail('Select at least one work item to add.');
        }
        CDO_Release__c r = loadRelease(releaseId);
        if (LOCKED_STATUSES.contains(r.Status__c)) {
            throw fail(r.Name + ' is ' + r.Status__c + '. Work items can no longer be added to it.');
        }
        List<CDO_Work_Item__c> items = [
            SELECT Id, Name, Project__c, Status__c, Release__c, Release__r.Name, Release__r.Status__c
            FROM CDO_Work_Item__c
            WHERE Id IN :workItemIds
        ];
        List<String> problems = new List<String>();
        List<CDO_Work_Item__c> updates = new List<CDO_Work_Item__c>();
        for (CDO_Work_Item__c wi : items) {
            if (wi.Release__c == r.Id) {
                continue;
            }
            if (wi.Project__c != null && r.Project__c != null && wi.Project__c != r.Project__c) {
                problems.add(wi.Name + ' belongs to another project');
            } else if (wi.Status__c == 'Cancelled') {
                problems.add(wi.Name + ' is cancelled');
            } else if (wi.Release__c != null && LOCKED_STATUSES.contains(wi.Release__r.Status__c)) {
                problems.add(wi.Name + ' is in ' + wi.Release__r.Name + ', which is ' + wi.Release__r.Status__c);
            } else {
                updates.add(new CDO_Work_Item__c(Id = wi.Id, Release__c = r.Id));
            }
        }
        if (!problems.isEmpty()) {
            throw fail('Cannot add to ' + r.Name + ': ' + String.join(problems, '; ') + '.');
        }
        try {
            update updates;
            if (!updates.isEmpty()) {
                CDO_Audit.log('Release', (updates.size() + ' work item(s) added to ' + r.Name).abbreviate(255),
                    String.join(namesOf(items), ', '), new Map<String, Id>{ 'release' => r.Id });
            }
            return updates.size();
        } catch (Exception e) {
            throw fail('Could not add the work items: ' + messageOf(e));
        }
    }

    @AuraEnabled
    public static void removeWorkItem(Id workItemId) {
        List<CDO_Work_Item__c> rows = workItemId == null ? new List<CDO_Work_Item__c>() : [
            SELECT Id, Name, Release__c, Release__r.Name, Release__r.Status__c
            FROM CDO_Work_Item__c
            WHERE Id = :workItemId
        ];
        if (rows.isEmpty()) {
            throw fail('That work item no longer exists or you do not have access to it.');
        }
        CDO_Work_Item__c wi = rows[0];
        if (wi.Release__c == null) {
            return;
        }
        if (LOCKED_STATUSES.contains(wi.Release__r.Status__c)) {
            throw fail(wi.Release__r.Name + ' is ' + wi.Release__r.Status__c + '. Its work items can no longer be removed.');
        }
        try {
            update new CDO_Work_Item__c(Id = wi.Id, Release__c = null);
            CDO_Audit.log('Release', (wi.Name + ' removed from ' + wi.Release__r.Name).abbreviate(255), null,
                new Map<String, Id>{ 'release' => wi.Release__c, 'workItem' => wi.Id });
        } catch (Exception e) {
            throw fail('Could not remove the work item: ' + messageOf(e));
        }
    }

    /** Cut the release branch from the release's work items (assemble-release.yml). */
    @AuraEnabled
    public static String assembleRelease(Id releaseId) {
        CDO_Release__c r = loadRelease(releaseId);
        if (!ASSEMBLE_FROM.contains(r.Status__c)) {
            throw fail(r.Name + ' is ' + r.Status__c + '. A release can be assembled when it is Planned, Ready or Failed.');
        }
        List<String> keys = namesOf(r.Work_Items__r);
        if (keys.isEmpty()) {
            throw fail('Add work items to ' + r.Name + ' before assembling it.');
        }
        IntegrationController.dispatchOrFail(GitHubService.WF_ASSEMBLE_RELEASE, new Map<String, String>{
            'release_id' => r.Id,
            'release_name' => r.Name,
            'work_items' => String.join(keys, ',')
        });
        try {
            update new CDO_Release__c(Id = r.Id, Status__c = 'Assembling');
            CDO_Audit.log('Release', ('Assembly of ' + r.Name + ' requested by ' + UserInfo.getName()).abbreviate(255),
                'Work items: ' + String.join(keys, ', '), new Map<String, Id>{ 'release' => r.Id });
        } catch (Exception e) {
            throw fail('The assemble workflow was started, but the release could not be updated: ' + messageOf(e));
        }
        return 'Assembling ' + r.Name + ' from ' + keys.size() + ' work item' + (keys.size() == 1 ? '' : 's') +
            '. The release branch appears here when the workflow reports back.';
    }

    /**
     * Start the production release (sf-prod-release.yml): validate in prod-validate, wait for the
     * required reviewer, quick-deploy the validated id, merge, tag. Needs CDO_Run_Prod_Release.
     */
    @AuraEnabled
    public static String releaseToProduction(Id releaseId) {
        if (!GovernanceController.hasPermission(GovernanceController.PERM_RUN_PROD_RELEASE)) {
            throw fail('Releasing to production needs the ' + GovernanceController.PERM_RUN_PROD_RELEASE +
                ' permission. Ask a release manager to run it.');
        }
        CDO_Release__c r = loadRelease(releaseId);
        if (!RELEASE_FROM.contains(r.Status__c)) {
            throw fail(r.Name + ' is ' + r.Status__c + '. Assemble it first; a release goes to production when it is Ready.');
        }
        if (String.isBlank(r.Release_Branch__c)) {
            throw fail(r.Name + ' has no release branch yet. Assemble it first.');
        }
        Set<String> tests = new Set<String>();
        for (CDO_Work_Item__c wi : r.Work_Items__r) {
            if (String.isNotBlank(wi.Specified_Tests__c)) {
                for (String t : wi.Specified_Tests__c.split(',')) {
                    if (String.isNotBlank(t)) {
                        tests.add(t.trim());
                    }
                }
            }
        }
        List<String> sortedTests = new List<String>(tests);
        sortedTests.sort();
        IntegrationController.dispatchOrFail(GitHubService.WF_PROD_RELEASE, new Map<String, String>{
            'release_id' => r.Id,
            'release_name' => r.Name,
            'source_ref' => r.Release_Branch__c,
            'test_level' => '',
            'specified_tests' => String.join(sortedTests, ','),
            'allow_destructive' => ''
        });
        try {
            update new CDO_Release__c(Id = r.Id, Status__c = 'Validating');
            CDO_Audit.log('Release', ('Production release of ' + r.Name + ' started by ' + UserInfo.getName()).abbreviate(255),
                'Source ref: ' + r.Release_Branch__c, new Map<String, Id>{ 'release' => r.Id });
        } catch (Exception e) {
            throw fail('The production release was started, but the release could not be updated: ' + messageOf(e));
        }
        return r.Name + ' is validating against production. Approve the prod environment in GitHub when the validation passes.';
    }

    // ----------------------------------------------------------------------------------------

    private static CDO_Release__c loadRelease(Id releaseId) {
        List<CDO_Release__c> rows = releaseId == null ? new List<CDO_Release__c>() : [
            SELECT Id, Name, Status__c, Project__c, Release_Branch__c,
                   (SELECT Id, Name, Specified_Tests__c FROM Work_Items__r WHERE Status__c != 'Cancelled' ORDER BY Name)
            FROM CDO_Release__c
            WHERE Id = :releaseId
        ];
        if (rows.isEmpty()) {
            throw fail('That release no longer exists or you do not have access to it.');
        }
        return rows[0];
    }

    private static List<String> namesOf(List<CDO_Work_Item__c> items) {
        List<String> names = new List<String>();
        for (CDO_Work_Item__c wi : items) {
            names.add(wi.Name);
        }
        return names;
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

    public class ReleaseView {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public Id projectId;
        @AuraEnabled public String projectName;
        @AuraEnabled public String version;
        @AuraEnabled public Date targetDate;
        @AuraEnabled public Datetime releasedOn;
        @AuraEnabled public String releaseBranch;
        @AuraEnabled public String tag;
        @AuraEnabled public String releaseUrl;
        @AuraEnabled public String runUrl;
        @AuraEnabled public String notes;
        @AuraEnabled public Integer workItemCount = 0;
        @AuraEnabled public Integer atProductionCount = 0;
        @AuraEnabled public Boolean canAssemble = false;
        @AuraEnabled public Boolean canRelease = false;
        @AuraEnabled public Boolean locked = false;
        @AuraEnabled public List<CDO_Work_Item__c> workItems = new List<CDO_Work_Item__c>();

        public ReleaseView(CDO_Release__c r) {
            id = r.Id;
            name = r.Name;
            status = r.Status__c;
            projectId = r.Project__c;
            projectName = r.Project__r?.Name;
            version = r.Version__c;
            targetDate = r.Target_Date__c;
            releasedOn = r.Released_On__c;
            releaseBranch = r.Release_Branch__c;
            tag = r.Tag__c;
            releaseUrl = r.Release_URL__c;
            runUrl = r.Workflow_Run_URL__c;
            notes = r.Notes__c;
            for (CDO_Work_Item__c wi : r.Work_Items__r) {
                if (wi.Status__c == 'Cancelled') {
                    continue;
                }
                workItems.add(wi);
                workItemCount++;
                if (wi.Current_Stage__r?.Is_Production__c == true) {
                    atProductionCount++;
                }
            }
            locked = LOCKED_STATUSES.contains(status);
            canAssemble = ASSEMBLE_FROM.contains(status) && workItemCount > 0;
            canRelease = RELEASE_FROM.contains(status) && String.isNotBlank(releaseBranch);
        }
    }
}
