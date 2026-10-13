/**
 * Quality evidence for a work item: static-analysis findings, the latest check-only validation,
 * and manual test scripts with their outcomes.
 */
public with sharing class QualityController {

    private static final Set<String> OUTCOMES = new Set<String>{ 'Pass', 'Fail', 'Blocked', 'Not_Run' };

    /** Findings, most severe first (the picklist is defined Critical → Info, and SOQL sorts by it). */
    @AuraEnabled(cacheable=true)
    public static FindingsView getFindings(Id workItemId) {
        FindingsView view = new FindingsView();
        if (workItemId == null) {
            return view;
        }
        view.findings = [
            SELECT Id, Name, Tool__c, Rule__c, Severity__c, File__c, Line__c, Message__c, Deployment__c,
                   Deployment__r.Name, CreatedDate
            FROM CDO_Scan_Finding__c
            WHERE Work_Item__c = :workItemId
            ORDER BY Severity__c ASC NULLS LAST, File__c, Line__c, Id
            LIMIT 2000
        ];
        for (CDO_Scan_Finding__c f : view.findings) {
            String sev = String.isBlank(f.Severity__c) ? 'Info' : f.Severity__c;
            view.bySeverity.put(sev, (view.bySeverity.containsKey(sev) ? view.bySeverity.get(sev) : 0) + 1);
        }
        view.total = view.findings.size();
        view.blocking = (view.bySeverity.containsKey('Critical') ? view.bySeverity.get('Critical') : 0) +
            (view.bySeverity.containsKey('High') ? view.bySeverity.get('High') : 0);
        return view;
    }

    /** The newest check-only validation for the work item, plus the work item's last-run summary. */
    @AuraEnabled(cacheable=true)
    public static ValidationView getLatestValidation(Id workItemId) {
        ValidationView view = new ValidationView();
        if (workItemId == null) {
            return view;
        }
        List<CDO_Work_Item__c> wis = [
            SELECT Id, Name, Last_Coverage__c, Last_Tests_Passed__c, Last_Validation_Status__c, Last_Run_URL__c,
                   Minimum_Coverage__c, Current_Stage__r.Coverage_Floor__c
            FROM CDO_Work_Item__c
            WHERE Id = :workItemId
        ];
        if (wis.isEmpty()) {
            return view;
        }
        CDO_Work_Item__c wi = wis[0];
        view.status = wi.Last_Validation_Status__c;
        view.coverage = wi.Last_Coverage__c;
        view.testsPassed = wi.Last_Tests_Passed__c;
        view.runUrl = wi.Last_Run_URL__c;
        view.minimumCoverage = wi.Minimum_Coverage__c != null ? wi.Minimum_Coverage__c : wi.Current_Stage__r?.Coverage_Floor__c;
        List<CDO_Deployment__c> rows = [
            SELECT Id, Name, Status__c, Event_Type__c, Check_Only__c, Coverage_Percent__c, Tests_Passed__c,
                   Failing_Methods__c, Message__c, Workflow_Run_URL__c, Deploy_Id__c, Commit_SHA__c, Test_Level__c,
                   Component_Count__c, Started_On__c, Completed_On__c, CreatedDate, Stage__r.Name, Environment__r.Name
            FROM CDO_Deployment__c
            WHERE Work_Item__c = :workItemId AND (Event_Type__c = 'Validation' OR Check_Only__c = true)
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        if (!rows.isEmpty()) {
            view.deployment = rows[0];
            if (String.isNotBlank(rows[0].Failing_Methods__c)) {
                for (String line : rows[0].Failing_Methods__c.split('\n')) {
                    if (String.isNotBlank(line)) {
                        view.failingMethods.add(line.trim());
                    }
                }
            }
        }
        view.belowMinimum = view.coverage != null && view.minimumCoverage != null && view.coverage < view.minimumCoverage;
        return view;
    }

    /** Manual test scripts with their latest result. */
    @AuraEnabled(cacheable=true)
    public static List<TestScriptRow> getTestScripts(Id workItemId) {
        List<TestScriptRow> rows = new List<TestScriptRow>();
        if (workItemId == null) {
            return rows;
        }
        for (CDO_Test_Script__c s : [
            SELECT Id, Name, Steps__c, Expected_Result__c, Order__c, Stage__c, Stage__r.Name,
                   (SELECT Id, Name, Outcome__c, Notes__c, Tested_On__c, Tested_By__r.Name, Stage__r.Name
                    FROM Test_Results__r ORDER BY CreatedDate DESC, Id DESC LIMIT 1)
            FROM CDO_Test_Script__c
            WHERE Work_Item__c = :workItemId
            ORDER BY Order__c ASC NULLS LAST, Name
            LIMIT 500
        ]) {
            rows.add(new TestScriptRow(s));
        }
        return rows;
    }

    /** Records one manual test outcome against the work item's current stage. */
    @AuraEnabled
    public static Id recordTestResult(Id testScriptId, String outcome, String notes) {
        String normalized = outcome == null ? '' : outcome.trim().replace(' ', '_');
        if (!OUTCOMES.contains(normalized)) {
            throw fail('Outcome must be Pass, Fail, Blocked or Not Run.');
        }
        if (normalized == 'Fail' && String.isBlank(notes)) {
            throw fail('Describe what failed in the notes.');
        }
        List<CDO_Test_Script__c> scripts = testScriptId == null ? new List<CDO_Test_Script__c>() : [
            SELECT Id, Name, Stage__c, Work_Item__c, Work_Item__r.Name, Work_Item__r.Current_Stage__c
            FROM CDO_Test_Script__c
            WHERE Id = :testScriptId
        ];
        if (scripts.isEmpty()) {
            throw fail('That test script no longer exists or you do not have access to it.');
        }
        CDO_Test_Script__c s = scripts[0];
        try {
            CDO_Test_Result__c r = new CDO_Test_Result__c(
                Test_Script__c = s.Id,
                Stage__c = s.Work_Item__r?.Current_Stage__c != null ? s.Work_Item__r.Current_Stage__c : s.Stage__c,
                Outcome__c = normalized,
                Tested_By__c = UserInfo.getUserId(),
                Tested_On__c = System.now(),
                Notes__c = String.isBlank(notes) ? null : notes.trim()
            );
            insert r;
            Map<String, Id> refs = new Map<String, Id>();
            if (s.Work_Item__c != null) {
                refs.put('workItem', s.Work_Item__c);
            }
            CDO_Audit.log(
                'Test',
                ('Test "' + s.Name + '" ' + normalized.replace('_', ' ') + ' by ' + UserInfo.getName()).abbreviate(255),
                r.Notes__c,
                refs
            );
            return r.Id;
        } catch (Exception e) {
            throw fail('Could not record the test result: ' + messageOf(e));
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

    // ----------------------------------------------------------------------------------------

    public class FindingsView {
        @AuraEnabled public Integer total = 0;
        @AuraEnabled public Integer blocking = 0;
        @AuraEnabled public Map<String, Integer> bySeverity = new Map<String, Integer>();
        @AuraEnabled public List<CDO_Scan_Finding__c> findings = new List<CDO_Scan_Finding__c>();
    }

    public class ValidationView {
        @AuraEnabled public String status;
        @AuraEnabled public Decimal coverage;
        @AuraEnabled public Decimal minimumCoverage;
        @AuraEnabled public Boolean belowMinimum = false;
        @AuraEnabled public Boolean testsPassed;
        @AuraEnabled public String runUrl;
        @AuraEnabled public CDO_Deployment__c deployment;
        @AuraEnabled public List<String> failingMethods = new List<String>();
    }

    public class TestScriptRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String steps;
        @AuraEnabled public String expectedResult;
        @AuraEnabled public Decimal sortOrder;
        @AuraEnabled public String stageName;
        @AuraEnabled public String lastOutcome;
        @AuraEnabled public String lastNotes;
        @AuraEnabled public Datetime lastTestedOn;
        @AuraEnabled public String lastTestedBy;

        public TestScriptRow(CDO_Test_Script__c s) {
            id = s.Id;
            name = s.Name;
            steps = s.Steps__c;
            expectedResult = s.Expected_Result__c;
            sortOrder = s.Order__c;
            stageName = s.Stage__r?.Name;
            lastOutcome = 'Not_Run';
            if (!s.Test_Results__r.isEmpty()) {
                CDO_Test_Result__c r = s.Test_Results__r[0];
                lastOutcome = r.Outcome__c;
                lastNotes = r.Notes__c;
                lastTestedOn = r.Tested_On__c;
                lastTestedBy = r.Tested_By__r?.Name;
            }
        }
    }
}
