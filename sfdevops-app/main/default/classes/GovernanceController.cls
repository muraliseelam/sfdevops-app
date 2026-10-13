/**
 * Governance read model and approvals for cdoGovernance: the audit log, pending (Draft)
 * promotions, approval decisions, and the custom-permission checks every controller shares.
 *
 * Approval starts the promotion (spec section 10): an Approved decision dispatches the Draft
 * promotion straight away, unless a carried work item's measured coverage is below its minimum.
 */
public with sharing class GovernanceController {

    public static final String PERM_APPROVE_ENTRY = 'CDO_Approve_Entry';
    public static final String PERM_RUN_PROD_RELEASE = 'CDO_Run_Prod_Release';
    public static final String PERM_GOVERNANCE_OPS = 'CDO_Governance_Ops';
    public static final String PERM_CONFIGURE_PIPELINE = 'CDO_Configure_Pipeline';

    private static final Integer DEFAULT_AUDIT_LIMIT = 100;
    private static final Integer MAX_AUDIT_LIMIT = 1000;

    /** Tests set this to simulate custom-permission grants without creating users. */
    @TestVisible
    private static Set<String> testPermissions;

    /**
     * True when the running user holds the custom permission. A permission that is not deployed
     * in this org yet counts as not granted.
     */
    public static Boolean hasPermission(String permissionName) {
        if (Test.isRunningTest() && testPermissions != null) {
            return testPermissions.contains(permissionName);
        }
        try {
            return FeatureManagement.checkPermission(permissionName);
        } catch (Exception e) {
            return false;
        }
    }

    /** What the running user may do, plus the pipeline keys the ops forms offer. */
    @AuraEnabled(cacheable=true)
    public static GovernanceContext getContext() {
        GovernanceContext ctx = new GovernanceContext();
        ctx.canApproveEntry = hasPermission(PERM_APPROVE_ENTRY);
        ctx.canRunProdRelease = hasPermission(PERM_RUN_PROD_RELEASE);
        ctx.canRunOps = hasPermission(PERM_GOVERNANCE_OPS);
        ctx.canConfigure = hasPermission(PERM_CONFIGURE_PIPELINE);
        Set<String> seen = new Set<String>();
        for (CDO_Stage__c s : [
            SELECT Pipeline_Key__c, Name
            FROM CDO_Stage__c
            WHERE Pipeline_Key__c != null
            ORDER BY Order__c ASC NULLS LAST, Name
            LIMIT 200
        ]) {
            if (seen.add(s.Pipeline_Key__c)) {
                ctx.pipelineKeys.add(new Option(s.Name + ' (' + s.Pipeline_Key__c + ')', s.Pipeline_Key__c));
            }
        }
        return ctx;
    }

    @AuraEnabled(cacheable=true)
    public static List<CDO_Audit_Event__c> getAuditEvents(String eventType, Id workItemId, Integer limitSize) {
        Integer rowLimit = (limitSize == null || limitSize <= 0) ? DEFAULT_AUDIT_LIMIT : Math.min(limitSize, MAX_AUDIT_LIMIT);
        List<String> filters = new List<String>();
        Map<String, Object> binds = new Map<String, Object>{ 'rowLimit' => rowLimit };
        if (String.isNotBlank(eventType)) {
            filters.add('Event_Type__c = :eventType');
            binds.put('eventType', eventType.trim());
        }
        if (workItemId != null) {
            filters.add('Work_Item__c = :workItemId');
            binds.put('workItemId', workItemId);
        }
        String soql =
            'SELECT Id, Name, Event_Type__c, Summary__c, Details__c, Actor__c, Source__c, Occurred_On__c, ' +
            'Run_URL__c, CreatedDate, Work_Item__c, Work_Item__r.Name, Promotion__c, Promotion__r.Name, ' +
            'Deployment__c, Deployment__r.Name, Release__c, Release__r.Name FROM CDO_Audit_Event__c' +
            (filters.isEmpty() ? '' : ' WHERE ' + String.join(filters, ' AND ')) +
            ' ORDER BY CreatedDate DESC, Id DESC LIMIT :rowLimit';
        return (List<CDO_Audit_Event__c>) Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE);
    }

    /** Distinct event types, for the audit-log filter. */
    @AuraEnabled(cacheable=true)
    public static List<String> getEventTypes() {
        List<String> types = new List<String>();
        for (AggregateResult ar : [
            SELECT Event_Type__c eventType
            FROM CDO_Audit_Event__c
            WHERE Event_Type__c != null
            GROUP BY Event_Type__c
            ORDER BY Event_Type__c
            LIMIT 200
        ]) {
            types.add((String) ar.get('eventType'));
        }
        return types;
    }

    @AuraEnabled(cacheable=true)
    public static List<CDO_Approval__c> getApprovals(Id promotionId) {
        if (promotionId == null) {
            return new List<CDO_Approval__c>();
        }
        return [
            SELECT Id, Name, Decision__c, Approver__c, Method__c, Decided_On__c, Comments__c, Source_URL__c,
                   Stage__c, Stage__r.Name, Work_Item__c, Work_Item__r.Name, Promotion__c, CreatedDate
            FROM CDO_Approval__c
            WHERE Promotion__c = :promotionId
            ORDER BY Decided_On__c DESC NULLS LAST, CreatedDate DESC, Id DESC
            LIMIT 200
        ];
    }

    /** Draft promotions: created, not dispatched, waiting for a decision. Oldest first. */
    @AuraEnabled(cacheable=true)
    public static List<PendingPromotion> getPendingPromotions() {
        List<PendingPromotion> pending = new List<PendingPromotion>();
        for (CDO_Promotion__c p : [
            SELECT Id, Name, Status__c, CreatedDate, Direction__c, Project__r.Name,
                   Source_Stage__r.Name, Target_Stage__c, Target_Stage__r.Name, Target_Stage__r.Gate_Type__c,
                   Target_Stage__r.Is_Entry__c, Target_Stage__r.Is_Production__c, Requested_By__r.Name,
                   (SELECT Work_Item__r.Name, Work_Item__r.Last_Coverage__c, Work_Item__r.Minimum_Coverage__c
                    FROM Promoted_Work_Items__r ORDER BY Work_Item__r.Name)
            FROM CDO_Promotion__c
            WHERE Status__c = 'Draft'
            ORDER BY CreatedDate ASC, Id ASC
            LIMIT 200
        ]) {
            pending.add(new PendingPromotion(p));
        }
        return pending;
    }

    /**
     * Records an approval decision against a Draft promotion and writes an audit event.
     * Approved: the promotion is dispatched (held back only for low coverage).
     * Rejected: the promotion is cancelled; a comment is required.
     */
    @AuraEnabled
    public static ApprovalResult recordApproval(Id promotionId, String decision, String comments) {
        String normalized = normalizeDecision(decision);
        if (promotionId == null) {
            throw fail('Choose a promotion to approve or reject.');
        }
        if (normalized == 'Rejected' && String.isBlank(comments)) {
            throw fail('Add a comment that explains the rejection.');
        }
        CDO_Promotion__c p = loadPromotion(promotionId);
        if (p.Status__c != 'Draft') {
            throw fail(p.Name + ' is ' + p.Status__c + '. Only a Draft promotion waits for an approval decision.');
        }
        String denial = approvalDenial(p);
        if (denial != null) {
            throw fail(denial);
        }

        try {
            CDO_Approval__c approval = new CDO_Approval__c(
                Promotion__c = p.Id,
                Stage__c = p.Target_Stage__c,
                Approver__c = UserInfo.getName(),
                Method__c = 'Manual',
                Decision__c = normalized,
                Decided_On__c = System.now(),
                Comments__c = String.isBlank(comments) ? null : comments.trim(),
                Work_Item__c = p.Promoted_Work_Items__r.size() == 1 ? p.Promoted_Work_Items__r[0].Work_Item__c : null
            );
            insert approval;

            ApprovalResult result = new ApprovalResult();
            result.approvalId = approval.Id;
            result.promotionId = p.Id;
            result.decision = normalized;
            Map<String, Id> refs = new Map<String, Id>{ 'promotion' => p.Id };
            if (approval.Work_Item__c != null) {
                refs.put('workItem', approval.Work_Item__c);
            }

            if (normalized == 'Rejected') {
                update new CDO_Promotion__c(
                    Id = p.Id,
                    Status__c = 'Cancelled',
                    Completed_On__c = System.now(),
                    Message__c = 'Rejected by ' + UserInfo.getName() + ': ' + comments.trim()
                );
                result.dispatched = false;
                result.promotionStatus = 'Cancelled';
                result.message = p.Name + ' rejected and cancelled.';
            } else {
                String hold = coverageHold(p);
                if (hold != null) {
                    result.dispatched = false;
                    result.promotionStatus = 'Draft';
                    result.message = p.Name + ' approved but held: ' + hold;
                } else {
                    CDOPromotionDispatcher.dispatchPromotion(p.Id);
                    result.dispatched = true;
                    result.promotionStatus = [SELECT Status__c FROM CDO_Promotion__c WHERE Id = :p.Id].Status__c;
                    result.message = p.Name + ' approved and ' +
                        (result.promotionStatus == 'Dispatched' ? 'sent to GitHub to deploy to ' : 'queued for deployment to ') +
                        p.Target_Stage__r.Name + '.';
                }
            }
            CDO_Audit.log(
                'Approval',
                abbreviate(result.message),
                'Decision: ' + normalized + '\nApprover: ' + UserInfo.getName() +
                    (String.isBlank(comments) ? '' : '\nComments: ' + comments.trim()),
                refs
            );
            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw fail('Could not record the decision on ' + p.Name + ': ' + messageOf(e));
        }
    }

    // ----------------------------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------------------------

    /** Null when the running user may decide on the promotion, otherwise the reason they may not. */
    @TestVisible
    private static String approvalDenial(CDO_Promotion__c p) {
        if (p.Target_Stage__r != null && p.Target_Stage__r.Is_Entry__c == true && !hasPermission(PERM_APPROVE_ENTRY)) {
            return 'Approving the entry stage ' + p.Target_Stage__r.Name + ' needs the ' + PERM_APPROVE_ENTRY +
                ' permission. Ask a release manager to approve ' + p.Name + '.';
        }
        if (p.Target_Stage__r != null && p.Target_Stage__r.Is_Production__c == true && !hasPermission(PERM_RUN_PROD_RELEASE)) {
            return 'Approving a production promotion needs the ' + PERM_RUN_PROD_RELEASE + ' permission.';
        }
        return null;
    }

    /** Spec section 10: hold an approved promotion back only when coverage is below the minimum. */
    @TestVisible
    private static String coverageHold(CDO_Promotion__c p) {
        List<String> low = new List<String>();
        for (CDO_Promoted_Work_Item__c j : p.Promoted_Work_Items__r) {
            CDO_Work_Item__c wi = j.Work_Item__r;
            if (wi != null && wi.Last_Coverage__c != null && wi.Minimum_Coverage__c != null &&
                wi.Last_Coverage__c < wi.Minimum_Coverage__c) {
                low.add(wi.Name + ' coverage ' + wi.Last_Coverage__c.setScale(1) + '% is below its minimum ' +
                    wi.Minimum_Coverage__c.setScale(1) + '%');
            }
        }
        return low.isEmpty() ? null : String.join(low, '; ') + '. Raise coverage, then deploy the promotion.';
    }

    private static String normalizeDecision(String decision) {
        String d = decision == null ? '' : decision.trim().toLowerCase();
        if (d == 'approved' || d == 'approve') {
            return 'Approved';
        }
        if (d == 'rejected' || d == 'reject') {
            return 'Rejected';
        }
        throw fail('Decision must be Approved or Rejected.');
    }

    private static CDO_Promotion__c loadPromotion(Id promotionId) {
        List<CDO_Promotion__c> rows = [
            SELECT Id, Name, Status__c, Target_Stage__c, Target_Stage__r.Name, Target_Stage__r.Is_Entry__c,
                   Target_Stage__r.Is_Production__c, Target_Stage__r.Gate_Type__c,
                   (SELECT Work_Item__c, Work_Item__r.Name, Work_Item__r.Last_Coverage__c, Work_Item__r.Minimum_Coverage__c
                    FROM Promoted_Work_Items__r)
            FROM CDO_Promotion__c
            WHERE Id = :promotionId
        ];
        if (rows.isEmpty()) {
            throw fail('That promotion no longer exists or you do not have access to it.');
        }
        return rows[0];
    }

    private static String abbreviate(String s) {
        return s == null ? null : s.abbreviate(255);
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
    // View models
    // ----------------------------------------------------------------------------------------

    public class GovernanceContext {
        @AuraEnabled public Boolean canApproveEntry;
        @AuraEnabled public Boolean canRunProdRelease;
        @AuraEnabled public Boolean canRunOps;
        @AuraEnabled public Boolean canConfigure;
        @AuraEnabled public List<Option> pipelineKeys = new List<Option>();
    }

    public class Option {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        public Option(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    public class PendingPromotion {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String direction;
        @AuraEnabled public String projectName;
        @AuraEnabled public String sourceStageName;
        @AuraEnabled public String targetStageName;
        @AuraEnabled public String gateType;
        @AuraEnabled public Boolean isEntry;
        @AuraEnabled public Boolean isProduction;
        @AuraEnabled public String requestedByName;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Integer workItemCount;
        @AuraEnabled public String workItems;
        @AuraEnabled public Boolean canApprove;
        @AuraEnabled public String approvalBlockedReason;
        @AuraEnabled public String coverageHold;

        public PendingPromotion(CDO_Promotion__c p) {
            id = p.Id;
            name = p.Name;
            status = p.Status__c;
            direction = p.Direction__c;
            projectName = p.Project__r?.Name;
            sourceStageName = p.Source_Stage__r?.Name;
            targetStageName = p.Target_Stage__r?.Name;
            gateType = p.Target_Stage__r?.Gate_Type__c;
            isEntry = p.Target_Stage__r?.Is_Entry__c == true;
            isProduction = p.Target_Stage__r?.Is_Production__c == true;
            requestedByName = p.Requested_By__r?.Name;
            createdDate = p.CreatedDate;
            List<String> keys = new List<String>();
            for (CDO_Promoted_Work_Item__c j : p.Promoted_Work_Items__r) {
                if (j.Work_Item__r != null) {
                    keys.add(j.Work_Item__r.Name);
                }
            }
            workItemCount = keys.size();
            workItems = String.join(keys, ', ');
            approvalBlockedReason = approvalDenial(p);
            canApprove = approvalBlockedReason == null;
            coverageHold = GovernanceController.coverageHold(p);
        }
    }

    public class ApprovalResult {
        @AuraEnabled public Id approvalId;
        @AuraEnabled public Id promotionId;
        @AuraEnabled public String decision;
        @AuraEnabled public String promotionStatus;
        @AuraEnabled public Boolean dispatched;
        @AuraEnabled public String message;
    }
}
