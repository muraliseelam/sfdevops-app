/**
 * Records the post-deploy merge outcome (docs/CONTRACTS.md section 2.2).
 *
 * merged = true: the promotion's Merge_SHA__c and its work items' Merge_State__c = Merged.
 * merged = false: the org was deployed but the branch was not merged (for example "target moved
 * during the run"). The promotion stays Deployed, its Message__c says what happened, its work items
 * go back to Not_Merged, and an audit event is written.
 *
 * inherited sharing: reached through CDO_MergeStatusResource's system-context hop.
 */
public inherited sharing class CDO_MergeStatusService {

    public static CDO_CallbackResource.CallbackResponse apply(CDO_MergeStatusResource.MergeStatusRequest req) {
        if (req == null) {
            throw new CDO_CallbackService.CallbackException('The merge-status body is empty.');
        }
        if (req.merged == null) {
            throw new CDO_CallbackService.CallbackException('merged (true or false) is required.');
        }
        Boolean ownsSource = CDO_Audit.getSource() == null;
        if (ownsSource) {
            CDO_Audit.setSource(CDO_Audit.SOURCE_GITHUB);
        }
        CDO_Audit.hold();
        try {
            CDO_Work_Item__c wi = findWorkItem(req.workItem);
            CDO_Promotion__c p = findPromotion(req, wi);
            if (p == null && wi == null) {
                throw new CDO_CallbackService.CallbackException('The merge status names no known promotion or work item.');
            }
            Set<Id> workItemIds = new Set<Id>();
            if (p != null) {
                for (CDO_Promoted_Work_Item__c row : p.Promoted_Work_Items__r) {
                    if (row.Work_Item__c != null) {
                        workItemIds.add(row.Work_Item__c);
                    }
                }
            }
            if (wi != null) {
                workItemIds.add(wi.Id);
            }
            String branch = String.isNotBlank(req.targetBranch)
                ? req.targetBranch.trim()
                : (p != null && String.isNotBlank(p.Target_Branch__c) ? p.Target_Branch__c : 'the target branch');
            String env = String.isNotBlank(req.environment)
                ? req.environment.trim()
                : (p != null && p.Target_Stage__r != null ? p.Target_Stage__r.Name : 'the target environment');
            String subject = p != null ? p.Name : wi.Name;
            String summary;
            List<CDO_Work_Item__c> items = new List<CDO_Work_Item__c>();

            if (req.merged) {
                if (p != null) {
                    if (String.isNotBlank(req.mergeSha)) {
                        p.Merge_SHA__c = req.mergeSha.trim().left(40);
                    }
                    if (String.isBlank(p.Target_Branch__c) && String.isNotBlank(req.targetBranch)) {
                        p.Target_Branch__c = req.targetBranch.trim().left(255);
                    }
                    update p;
                }
                for (Id i : workItemIds) {
                    items.add(new CDO_Work_Item__c(Id = i, Merge_State__c = 'Merged'));
                }
                summary = subject + ' merged into ' + branch +
                    (String.isBlank(req.mergeSha) ? '.' : ' at ' + req.mergeSha.trim().left(7) + '.');
            } else {
                String reason = String.isBlank(req.reason) ? 'no reason was given' : req.reason.trim();
                summary = subject + ' was deployed to ' + env + ' but not merged into ' + branch + ': ' + reason;
                if (p != null) {
                    // The status stays Deployed: the org has the change even though the branch does not.
                    p.Message__c = summary.left(32768);
                    update p;
                }
                for (Id i : workItemIds) {
                    items.add(new CDO_Work_Item__c(Id = i, Merge_State__c = 'Not_Merged'));
                }
                CDO_NotificationService.notify(
                    'Promotion',
                    summary,
                    new Map<String, Object>{
                        'promotion' => p == null ? null : p.Name,
                        'workItem' => wi == null ? null : wi.Name,
                        'environment' => req.environment,
                        'targetBranch' => req.targetBranch,
                        'reason' => reason,
                        'runUrl' => req.runUrl
                    }
                );
            }
            update items;

            Map<String, Id> refs = new Map<String, Id>();
            if (p != null) {
                refs.put('promotion', p.Id);
            }
            if (wi != null) {
                refs.put('workItem', wi.Id);
            }
            CDO_Audit_Event__c ev = CDO_Audit.build(
                req.merged ? 'MergeStatus.Merged' : 'MergeStatus.NotMerged',
                summary,
                JSON.serializePretty(req, true),
                refs
            );
            if (String.isNotBlank(req.runUrl) && req.runUrl.trim().length() <= 255) {
                ev.Run_URL__c = req.runUrl.trim();
            }
            CDO_Audit.log(ev);
            return new CDO_CallbackResource.CallbackResponse(true, null, summary);
        } finally {
            CDO_Audit.release();
            if (ownsSource) {
                CDO_Audit.setSource(null);
            }
        }
    }

    private static CDO_Work_Item__c findWorkItem(String key) {
        if (String.isBlank(key)) {
            return null;
        }
        String name = key.trim();
        List<CDO_Work_Item__c> rows = [SELECT Id, Name FROM CDO_Work_Item__c WHERE Name = :name LIMIT 1];
        return rows.isEmpty() ? null : rows[0];
    }

    /** promotionId; else the promotion with this run URL; else the latest promotion of the work item to that environment. */
    private static CDO_Promotion__c findPromotion(CDO_MergeStatusResource.MergeStatusRequest req, CDO_Work_Item__c wi) {
        Id promotionId = CDO_CallbackService.toId(req.promotionId, CDO_Promotion__c.SObjectType, 'promotionId');
        if (promotionId != null) {
            List<CDO_Promotion__c> byId = query(new Set<Id>{ promotionId });
            if (byId.isEmpty()) {
                throw new CDO_CallbackService.CallbackException('Unknown promotion ' + req.promotionId + '.');
            }
            return byId[0];
        }
        String runUrl = String.isBlank(req.runUrl) ? null : req.runUrl.trim();
        if (runUrl != null && runUrl.length() <= 255) {
            Set<Id> ids = new Map<Id, CDO_Promotion__c>(
                [SELECT Id FROM CDO_Promotion__c WHERE Workflow_Run_URL__c = :runUrl ORDER BY CreatedDate DESC, Id DESC LIMIT 1]
            ).keySet();
            if (!ids.isEmpty()) {
                return query(ids)[0];
            }
        }
        if (wi != null && String.isNotBlank(req.environment)) {
            String envKey = req.environment.trim();
            Id wiId = wi.Id;
            Set<Id> ids = new Map<Id, CDO_Promotion__c>(
                [
                    SELECT Id FROM CDO_Promotion__c
                    WHERE Target_Stage__r.Pipeline_Key__c = :envKey
                        AND Id IN (SELECT Promotion__c FROM CDO_Promoted_Work_Item__c WHERE Work_Item__c = :wiId)
                    ORDER BY CreatedDate DESC, Id DESC
                    LIMIT 1
                ]
            ).keySet();
            if (!ids.isEmpty()) {
                return query(ids)[0];
            }
        }
        return null;
    }

    private static List<CDO_Promotion__c> query(Set<Id> ids) {
        return [
            SELECT Id, Name, Status__c, Target_Branch__c, Merge_SHA__c, Message__c, Target_Stage__r.Name,
                (SELECT Id, Work_Item__c FROM Promoted_Work_Items__r)
            FROM CDO_Promotion__c
            WHERE Id IN :ids
        ];
    }
}
