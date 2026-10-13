/**
 * Manual pre-, deploy- and post-deployment steps on a work item (cdoDeploymentSteps): list, add,
 * edit, complete, delete and reorder. Only the editable fields are taken from the client; who
 * completed a step and when is always stamped here.
 */
public with sharing class DeploymentStepController {

    private static final Set<String> PHASES = new Set<String>{ 'Pre', 'Deploy', 'Post' };
    private static final Set<String> TYPES = new Set<String>{ 'Manual', 'Apex', 'Data', 'Command' };
    private static final Set<String> EDITABLE_STATUSES = new Set<String>{ 'Pending', 'In_Progress', 'Skipped', 'Failed' };

    /** Steps in run order: phase (Pre, Deploy, Post), then Order__c. */
    @AuraEnabled(cacheable=true)
    public static List<CDO_Deployment_Step__c> getSteps(Id workItemId) {
        if (workItemId == null) {
            return new List<CDO_Deployment_Step__c>();
        }
        return [
            SELECT Id, Name, Work_Item__c, Deployment__c, Deployment__r.Name, Stage__c, Stage__r.Name, Phase__c, Order__c,
                   Type__c, Instructions__c, Status__c, Completed_By__c, Completed_By__r.Name, Completed_On__c, CreatedDate
            FROM CDO_Deployment_Step__c
            WHERE Work_Item__c = :workItemId
            ORDER BY Phase__c ASC NULLS LAST, Order__c ASC NULLS LAST, CreatedDate ASC, Id ASC
            LIMIT 500
        ];
    }

    @AuraEnabled
    public static Id saveStep(CDO_Deployment_Step__c s) {
        if (s == null) {
            throw fail('Nothing to save.');
        }
        CDO_Deployment_Step__c existing;
        if (s.Id != null) {
            existing = loadStep(s.Id);
        } else if (s.Work_Item__c == null) {
            throw fail('A step belongs to a work item. Open the work item to add steps.');
        }
        String phase = String.isBlank(s.Phase__c) ? (existing != null ? existing.Phase__c : 'Pre') : s.Phase__c;
        String stepType = String.isBlank(s.Type__c) ? (existing != null ? existing.Type__c : 'Manual') : s.Type__c;
        if (!PHASES.contains(phase)) {
            throw fail('Phase must be Pre, Deploy or Post.');
        }
        if (!TYPES.contains(stepType)) {
            throw fail('Type must be Manual, Apex, Data or Command.');
        }
        if (String.isBlank(s.Instructions__c) && String.isBlank(s.Name)) {
            throw fail('Enter a name or instructions for the step.');
        }
        CDO_Deployment_Step__c rec = new CDO_Deployment_Step__c(Id = s.Id);
        Id workItemId = existing != null ? existing.Work_Item__c : s.Work_Item__c;
        if (existing == null) {
            rec.Work_Item__c = workItemId;
            rec.Status__c = 'Pending';
            rec.Order__c = s.Order__c != null ? s.Order__c : nextOrder(workItemId, phase);
        } else if (s.Order__c != null) {
            rec.Order__c = s.Order__c;
        }
        if (existing != null && s.Status__c != null && s.Status__c != existing.Status__c) {
            if (!EDITABLE_STATUSES.contains(s.Status__c)) {
                throw fail('Use Complete to mark a step done.');
            }
            rec.Status__c = s.Status__c;
        }
        rec.Name = String.isBlank(s.Name) ? s.Instructions__c.normalizeSpace().abbreviate(80) : s.Name.trim().abbreviate(80);
        rec.Phase__c = phase;
        rec.Type__c = stepType;
        rec.Instructions__c = s.Instructions__c;
        rec.Stage__c = s.Stage__c;
        rec.Deployment__c = s.Deployment__c;
        try {
            upsert rec;
            return rec.Id;
        } catch (Exception e) {
            throw fail('Could not save the step: ' + messageOf(e));
        }
    }

    @AuraEnabled
    public static CDO_Deployment_Step__c completeStep(Id stepId) {
        CDO_Deployment_Step__c step = loadStep(stepId);
        if (step.Status__c == 'Done') {
            return step;
        }
        try {
            update new CDO_Deployment_Step__c(
                Id = step.Id,
                Status__c = 'Done',
                Completed_By__c = UserInfo.getUserId(),
                Completed_On__c = System.now()
            );
            Map<String, Id> refs = new Map<String, Id>();
            if (step.Work_Item__c != null) {
                refs.put('workItem', step.Work_Item__c);
            }
            if (step.Deployment__c != null) {
                refs.put('deployment', step.Deployment__c);
            }
            CDO_Audit.log('Deployment Step',
                (step.Phase__c + ' step "' + step.Name + '" completed by ' + UserInfo.getName()).abbreviate(255),
                step.Instructions__c, refs);
        } catch (Exception e) {
            throw fail('Could not complete the step: ' + messageOf(e));
        }
        return loadStep(stepId);
    }

    @AuraEnabled
    public static void deleteStep(Id stepId) {
        CDO_Deployment_Step__c step = loadStep(stepId);
        if (step.Status__c == 'Done') {
            throw fail('"' + step.Name + '" is done and is part of the record of what was deployed. It cannot be deleted.');
        }
        try {
            delete new CDO_Deployment_Step__c(Id = step.Id);
        } catch (Exception e) {
            throw fail('Could not delete the step: ' + messageOf(e));
        }
    }

    /** Sets Order__c to 1..n in the given sequence. All steps must belong to one work item. */
    @AuraEnabled
    public static void reorder(List<Id> stepIds) {
        if (stepIds == null || stepIds.isEmpty()) {
            return;
        }
        Map<Id, CDO_Deployment_Step__c> steps = new Map<Id, CDO_Deployment_Step__c>(
            [SELECT Id, Work_Item__c FROM CDO_Deployment_Step__c WHERE Id IN :stepIds]
        );
        Set<Id> workItems = new Set<Id>();
        for (CDO_Deployment_Step__c s : steps.values()) {
            workItems.add(s.Work_Item__c);
        }
        if (steps.size() != new Set<Id>(stepIds).size()) {
            throw fail('Some steps no longer exist. Refresh and try again.');
        }
        if (workItems.size() > 1) {
            throw fail('Steps from different work items cannot be reordered together.');
        }
        List<CDO_Deployment_Step__c> updates = new List<CDO_Deployment_Step__c>();
        Integer position = 0;
        for (Id stepId : stepIds) {
            updates.add(new CDO_Deployment_Step__c(Id = stepId, Order__c = ++position));
        }
        try {
            update updates;
        } catch (Exception e) {
            throw fail('Could not reorder the steps: ' + messageOf(e));
        }
    }

    // ----------------------------------------------------------------------------------------

    private static Decimal nextOrder(Id workItemId, String phase) {
        AggregateResult ar = [
            SELECT MAX(Order__c) maxOrder
            FROM CDO_Deployment_Step__c
            WHERE Work_Item__c = :workItemId AND Phase__c = :phase
        ];
        Decimal maxOrder = (Decimal) ar.get('maxOrder');
        return maxOrder == null ? 1 : maxOrder + 1;
    }

    private static CDO_Deployment_Step__c loadStep(Id stepId) {
        List<CDO_Deployment_Step__c> rows = stepId == null ? new List<CDO_Deployment_Step__c>() : [
            SELECT Id, Name, Work_Item__c, Deployment__c, Stage__c, Phase__c, Order__c, Type__c, Instructions__c,
                   Status__c, Completed_By__c, Completed_By__r.Name, Completed_On__c
            FROM CDO_Deployment_Step__c
            WHERE Id = :stepId
        ];
        if (rows.isEmpty()) {
            throw fail('That step no longer exists or you do not have access to it.');
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
}
