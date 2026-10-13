/**
 * Applies inbound pipeline callbacks (docs/CONTRACTS.md section 2.1) to the hub's records.
 *
 * Rules this class exists to keep:
 * - De-dup: a deployment is found by its run URL; failing that, by the open Running deployment for
 *   the same work (promotion, work item, release or bare environment) and stage. A row is inserted
 *   only when both miss, so the ordinary Running -> Success pair leaves one row, not two.
 * - "Latest" always means ORDER BY CreatedDate DESC, Id DESC.
 * - Health_Status__c is written only as Healthy (a real deploy succeeded) or Degraded (a real deploy
 *   failed). Nothing else touches it, so an environment nothing has been deployed to stays blank.
 * - A promotion is never left without CDO_Promoted_Work_Item__c rows. The entry hop creates the
 *   promotion and its junction row before anything is recorded against it.
 * - Every call writes one CDO_Audit_Event__c.
 *
 * inherited sharing: the REST resources reach this class through a deliberate system-context hop
 * (see CDO_CallbackResource.SystemContext); any other caller keeps its own sharing.
 */
public inherited sharing class CDO_CallbackService {

    /** Bad input: the REST resources answer HTTP 400. */
    public class CallbackException extends Exception {}

    public static final String RUNNING = 'Running';
    public static final String SUCCESS = 'Success';
    public static final String FAILED = 'Failed';
    public static final String CANCELLED = 'Cancelled';

    public static final List<String> EVENT_TYPES = new List<String>{
        'Commit', 'Validation', 'Deploy', 'QuickDeploy', 'PullRequest', 'Approval',
        'Conflict', 'Merge', 'Release', 'Data', 'Rollback'
    };
    public static final List<String> TEST_LEVELS = new List<String>{
        'NoTestRun', 'RunSpecifiedTests', 'RunLocalTests', 'RunAllTestsInOrg'
    };

    private static final Set<String> RUNNING_WORDS = new Set<String>{ 'running', 'inprogress', 'started', 'queued', 'pending', 'deploying' };
    private static final Set<String> SUCCESS_WORDS = new Set<String>{ 'success', 'succeeded', 'successful', 'passed', 'deployed', 'ok' };
    private static final Set<String> FAILED_WORDS = new Set<String>{ 'failed', 'failure', 'fail', 'error', 'errored' };
    private static final Set<String> CANCELLED_WORDS = new Set<String>{ 'cancelled', 'canceled', 'aborted', 'skipped' };

    private static final Set<String> CLOSED_ITEMS = new Set<String>{ 'Done', 'Cancelled' };
    /** Statuses a new commit moves to Committed. Later statuses are left alone. */
    private static final Set<String> PRE_REVIEW = new Set<String>{ 'New', 'In_Progress', 'Committed', 'Blocked' };
    /** Statuses an approval moves to Approved. */
    private static final Set<String> PRE_APPROVAL = new Set<String>{ 'New', 'In_Progress', 'Committed', 'In_Review' };
    private static final Integer LONG_TEXT = 32768;
    private static final Integer MAX_FINDINGS = 1000;

    /** What one callback resolved to, and what it did. */
    private class Context {
        public CDO_CallbackResource.CallbackRequest req;
        public String status;
        public String eventType;
        public CDO_Work_Item__c workItem;
        public CDO_Promotion__c promotion;
        public CDO_Release__c release;
        public CDO_Stage__c stage;
        public Id environmentId;
        public Id projectId;
        public CDO_Deployment__c deployment;
        public Boolean checkOnly = false;
        public Boolean ownsSource = false;
        public String summary;
        public String notifyCategory;
        public List<String> notes = new List<String>();
    }

    // ---- Public API (docs/CONTRACTS.md section 4) --------------------------------------------------

    /** Promotion-scoped events (promotionId set). Release and work-item events are routed on. */
    public static CDO_CallbackResource.CallbackResponse apply(CDO_CallbackResource.CallbackRequest req) {
        return run(req);
    }

    /** Work-item-scoped events (no promotionId), including release events when releaseId is set. */
    public static CDO_CallbackResource.CallbackResponse applyWorkItemEvent(CDO_CallbackResource.CallbackRequest req) {
        return run(req);
    }

    private static CDO_CallbackResource.CallbackResponse run(CDO_CallbackResource.CallbackRequest req) {
        if (req == null) {
            throw new CallbackException('The callback body is empty.');
        }
        Context ctx = new Context();
        ctx.req = req;
        ctx.status = normalizeStatus(req.status);
        ctx.eventType = normalizeEventType(req.eventType);
        ctx.ownsSource = CDO_Audit.getSource() == null;
        if (ctx.ownsSource) {
            CDO_Audit.setSource(CDO_Audit.SOURCE_GITHUB);
        }
        CDO_Audit.hold();
        try {
            if (String.isNotBlank(req.promotionId)) {
                applyPromotion(ctx);
            } else if (String.isNotBlank(req.releaseId)) {
                applyRelease(ctx);
            } else {
                applyWorkItem(ctx);
            }
            return finish(ctx);
        } finally {
            CDO_Audit.release();
            if (ctx.ownsSource) {
                CDO_Audit.setSource(null);
            }
        }
    }

    // ---- Promotion-scoped ------------------------------------------------------------------------

    private static void applyPromotion(Context ctx) {
        Id promotionId = toId(ctx.req.promotionId, CDO_Promotion__c.SObjectType, 'promotionId');
        ctx.promotion = loadPromotion(promotionId);
        if (ctx.promotion == null) {
            throw new CallbackException('Unknown promotion ' + ctx.req.promotionId + '.');
        }
        if (ctx.projectId == null) {
            ctx.projectId = ctx.promotion.Project__c;
        }
        resolveWorkItem(ctx, false);
        ctx.stage = loadStage(ctx.promotion.Target_Stage__c);
        if (ctx.stage == null) {
            resolveStage(ctx);
        }
        ctx.environmentId = ctx.stage == null ? null : ctx.stage.Environment__c;
        if (ctx.eventType == null) {
            ctx.eventType = 'Deploy';
        }
        ctx.checkOnly = ctx.eventType == 'Validation' || ctx.req.checkOnly == true || ctx.promotion.Check_Only__c == true;

        List<CDO_Promoted_Work_Item__c> rows = junction(ctx.promotion.Id);
        if (rows.isEmpty() && ctx.workItem != null) {
            // A promotion without junction rows can never resolve. Heal it from the callback.
            insert CDOPromotionDispatcher.junctionRows(ctx.promotion.Id, new List<CDO_Work_Item__c>{ ctx.workItem });
            rows = junction(ctx.promotion.Id);
            ctx.notes.add('Junction row created for ' + ctx.workItem.Name + ': the promotion had none.');
        }
        if (ctx.workItem == null && rows.size() == 1 && rows[0].Work_Item__c != null) {
            ctx.workItem = loadWorkItemById(rows[0].Work_Item__c);
        }

        switch on ctx.eventType {
            when 'Deploy', 'QuickDeploy', 'Validation' {
                promotionDeploy(ctx, rows);
            }
            when 'Conflict' {
                promotionConflict(ctx, rows);
            }
            when 'Merge' {
                promotionMerge(ctx);
            }
            when 'Approval' {
                handleApproval(ctx);
            }
            when 'Commit' {
                handleCommit(ctx);
            }
            when 'PullRequest' {
                handlePullRequest(ctx);
            }
            when else {
                handleUnknown(ctx);
            }
        }
    }

    private static void promotionDeploy(Context ctx, List<CDO_Promoted_Work_Item__c> rows) {
        requireStatus(ctx);
        CDO_CallbackResource.CallbackRequest req = ctx.req;
        CDO_Promotion__c p = ctx.promotion;
        String stageName = stageLabel(ctx);
        Boolean alreadyDeployed = p.Status__c == 'Deployed';
        if (alreadyDeployed && (ctx.status == RUNNING || ctx.status == SUCCESS)) {
            // A repeated success or a late Running: Deployed is final. Touch the matching deployment
            // row if there is one, never insert a second row and never reopen the promotion.
            recordDeployment(ctx, ctx.eventType, false);
            ctx.summary = ctx.status == RUNNING
                ? p.Name + ' reported Running after it was Deployed; its status was kept.'
                : 'Repeated success for ' + p.Name + ' on ' + stageName + '; nothing was applied twice.';
            return;
        }
        stampRun(p, req);
        if (ctx.status == RUNNING) {
            p.Status__c = 'Deploying';
            update p;
            recordDeployment(ctx, ctx.eventType);
            ctx.summary = p.Name + ' is deploying to ' + stageName + '.';
            return;
        }
        p.Completed_On__c = System.now();
        ctx.notifyCategory = 'Promotion';
        if (ctx.status == SUCCESS) {
            p.Status__c = 'Deployed';
            if (ctx.checkOnly) {
                p.Message__c = 'Check-only validation passed. Nothing was deployed and no work item moved.';
            } else {
                p.Message__c = fit(req.message, LONG_TEXT);
                if (String.isNotBlank(req.commitSha)) {
                    p.Merge_SHA__c = fit(req.commitSha, 40);
                }
            }
            update p;
            recordDeployment(ctx, ctx.eventType);
            if (!ctx.checkOnly) {
                CDO_PromotionReconciler.resolvePromotedWorkItems(p.Id);
                updateEnvironmentHealth(ctx);
            }
            ctx.summary = p.Name + (ctx.checkOnly ? ' validated against ' : ' deployed to ') + stageName + '.';
        } else if (ctx.status == FAILED) {
            String msg = String.isBlank(req.message) ? 'Deployment to ' + stageName + ' failed.' : req.message.trim();
            p.Status__c = 'Failed';
            p.Message__c = fit(msg, LONG_TEXT);
            update p;
            recordDeployment(ctx, ctx.eventType);
            setJunctionStatus(rows, 'Failed');
            Set<Id> ids = workItemIds(rows);
            if (!ids.isEmpty()) {
                CDO_WorkItemService.markBlocked(ids, p.Name + ' to ' + stageName + ' failed: ' + msg);
            }
            if (!ctx.checkOnly) {
                updateEnvironmentHealth(ctx);
            }
            ctx.summary = p.Name + ' failed on ' + stageName + '.';
        } else {
            p.Status__c = 'Cancelled';
            p.Message__c = fit(String.isBlank(req.message) ? 'The workflow run was cancelled.' : req.message, LONG_TEXT);
            update p;
            recordDeployment(ctx, ctx.eventType);
            ctx.summary = p.Name + ' was cancelled on ' + stageName + '.';
        }
        CDOPromotionDispatcher.onPromotionFinished(p.Id);
    }

    private static void promotionConflict(Context ctx, List<CDO_Promoted_Work_Item__c> rows) {
        CDO_CallbackResource.CallbackRequest req = ctx.req;
        CDO_Promotion__c p = ctx.promotion;
        String stageName = stageLabel(ctx);
        List<String> paths = splitLines(req.conflictPaths);
        stampRun(p, req);
        p.Status__c = 'Conflict';
        p.Completed_On__c = System.now();
        p.Message__c = fit(
            String.isBlank(req.message) ? 'Merge conflict while cutting the promotion branch for ' + stageName + '.' : req.message,
            LONG_TEXT
        );
        update p;
        setJunctionStatus(rows, 'Conflict');

        Set<Id> ids = workItemIds(rows);
        String reason = 'Merge conflict promoting ' + p.Name + ' to ' + stageName + describePaths(paths);
        List<CDO_Work_Item__c> items = new List<CDO_Work_Item__c>();
        for (CDO_Work_Item__c wi : [SELECT Id, Status__c FROM CDO_Work_Item__c WHERE Id IN :ids]) {
            if (wi.Status__c == 'Cancelled') {
                continue;
            }
            items.add(
                new CDO_Work_Item__c(
                    Id = wi.Id,
                    Merge_State__c = 'Conflict',
                    Status__c = 'Blocked',
                    Conflict_Paths__c = fit(req.conflictPaths, LONG_TEXT),
                    Blocked_Reason__c = fit(reason, LONG_TEXT)
                )
            );
        }
        update items;
        if (!paths.isEmpty() && !ids.isEmpty()) {
            List<CDO_Component__c> components = [
                SELECT Id FROM CDO_Component__c
                WHERE Work_Item__c IN :ids AND Path__c IN :paths AND Has_Conflict__c = false
            ];
            for (CDO_Component__c c : components) {
                c.Has_Conflict__c = true;
            }
            update components;
        }
        // The deploy never ran: close an open Running row rather than leave it running forever.
        CDO_Deployment__c open = findDeployment(ctx);
        if (open != null && open.Status__c == RUNNING) {
            open.Status__c = FAILED;
            open.Message__c = fit('Merge conflict: ' + p.Message__c, LONG_TEXT);
            open.Completed_On__c = System.now();
            update open;
            ctx.deployment = open;
        }
        ctx.summary = reason;
        ctx.notifyCategory = 'Conflict';
        CDOPromotionDispatcher.onPromotionFinished(p.Id);
    }

    private static void promotionMerge(Context ctx) {
        CDO_Promotion__c p = ctx.promotion;
        if (ctx.status == SUCCESS && String.isNotBlank(ctx.req.commitSha)) {
            p.Merge_SHA__c = fit(ctx.req.commitSha, 40);
            update p;
        }
        ctx.summary = 'Merge ' + (ctx.status == null ? 'event' : ctx.status) + ' for ' + p.Name + '.';
    }

    // ---- Work-item-scoped ------------------------------------------------------------------------

    private static void applyWorkItem(Context ctx) {
        if (ctx.eventType == null) {
            throw new CallbackException('eventType is required for a work-item event.');
        }
        switch on ctx.eventType {
            when 'Commit' {
                handleCommit(ctx);
            }
            when 'PullRequest' {
                handlePullRequest(ctx);
            }
            when 'Validation' {
                handleValidation(ctx);
            }
            when 'Approval' {
                handleApproval(ctx);
            }
            when 'Deploy', 'QuickDeploy', 'Rollback', 'Data' {
                handleDeploy(ctx);
            }
            when 'Conflict' {
                handleConflictCheck(ctx);
            }
            when 'Merge' {
                handleMerge(ctx);
            }
            when 'Release' {
                throw new CallbackException('A Release event needs a releaseId.');
            }
            when else {
                handleUnknown(ctx);
            }
        }
    }

    private static void handleCommit(Context ctx) {
        resolveWorkItem(ctx, true);
        CDO_CallbackResource.CallbackRequest req = ctx.req;
        CDO_Work_Item__c wi = ctx.workItem;
        if (ctx.status == RUNNING) {
            ctx.summary = 'Commit for ' + wi.Name + ' is running.';
            return;
        }
        ctx.notifyCategory = 'Commit';
        if (ctx.status == FAILED || ctx.status == CANCELLED) {
            ctx.summary = 'Commit for ' + wi.Name + ' ' + ctx.status.toLowerCase() +
                (String.isBlank(req.message) ? '.' : ': ' + req.message.trim());
            return;
        }
        String sha = fit(req.commitSha, 40);
        if (sha == null) {
            throw new CallbackException('commitSha is required for a successful Commit event.');
        }
        String branch = CDO_WorkItemService.featureBranch(wi);
        List<CDO_Commit__c> existing = [SELECT Id FROM CDO_Commit__c WHERE SHA__c = :sha LIMIT 1];
        CDO_Commit__c c = existing.isEmpty() ? new CDO_Commit__c(Work_Item__c = wi.Id, SHA__c = sha) : existing[0];
        c.Name = (sha.left(7) + ' ' + firstLine(req.message)).trim().abbreviate(80);
        c.Branch__c = fit(branch, 255);
        if (String.isNotBlank(req.message)) {
            c.Message__c = fit(req.message, LONG_TEXT);
        }
        Integer count = req.componentCount != null ? req.componentCount : (req.components == null ? null : req.components.size());
        if (count != null) {
            c.Component_Count__c = count;
        }
        if (url(req.runUrl) != null) {
            c.Workflow_Run_URL__c = url(req.runUrl);
        }
        if (String.isNotBlank(req.approver)) {
            c.Committed_By__c = fit(req.approver, 255);
        }
        c.Committed_On__c = System.now();
        upsert c;

        Integer written = upsertComponents(wi, req.components, sha);
        CDO_Work_Item__c upd = new CDO_Work_Item__c(Id = wi.Id, Last_Commit_SHA__c = sha);
        if (String.isBlank(wi.Feature_Branch__c)) {
            upd.Feature_Branch__c = fit(branch, 255);
        }
        if (wi.Status__c == null || PRE_REVIEW.contains(wi.Status__c)) {
            upd.Status__c = 'Committed';
        }
        update upd;
        ctx.summary = wi.Name + ' committed ' + sha.left(7) + ' (' + written + ' component' + (written == 1 ? '' : 's') + ') to ' + branch + '.';
    }

    private static Integer upsertComponents(CDO_Work_Item__c wi, List<CDO_CallbackResource.ComponentPayload> payloads, String sha) {
        if (payloads == null || payloads.isEmpty()) {
            return 0;
        }
        Map<String, CDO_CallbackResource.ComponentPayload> byKey = new Map<String, CDO_CallbackResource.ComponentPayload>();
        Map<String, String> keyText = new Map<String, String>();
        for (CDO_CallbackResource.ComponentPayload payload : payloads) {
            if (payload == null || String.isBlank(payload.type) || String.isBlank(payload.name)) {
                continue;
            }
            String key = componentKey(wi.Name, payload.type, payload.name);
            byKey.put(key.toLowerCase(), payload);
            keyText.put(key.toLowerCase(), key);
        }
        if (byKey.isEmpty()) {
            return 0;
        }
        List<String> keys = keyText.values();
        Map<String, CDO_Component__c> existing = new Map<String, CDO_Component__c>();
        for (CDO_Component__c row : [SELECT Id, Work_Item_Key__c FROM CDO_Component__c WHERE Work_Item_Key__c IN :keys]) {
            existing.put(row.Work_Item_Key__c.toLowerCase(), row);
        }
        List<CDO_Component__c> inserts = new List<CDO_Component__c>();
        List<CDO_Component__c> updates = new List<CDO_Component__c>();
        for (String lower : byKey.keySet()) {
            CDO_CallbackResource.ComponentPayload payload = byKey.get(lower);
            CDO_Component__c row = existing.get(lower);
            Boolean isNew = row == null;
            if (isNew) {
                row = new CDO_Component__c(Work_Item__c = wi.Id, Work_Item_Key__c = keyText.get(lower));
            }
            String mdType = payload.type.trim();
            String member = payload.name.trim();
            row.Name = (mdType + ':' + member).abbreviate(80);
            row.Metadata_Type__c = fit(mdType, 80);
            row.Member_Name__c = fit(member, 255);
            row.Unique_ID__c = fit(String.isBlank(payload.uniqueId) ? mdType + ':' + member : payload.uniqueId, 255);
            String action = normalizeAction(payload.action);
            if (action != null) {
                row.Action__c = action;
            }
            if (String.isNotBlank(payload.path)) {
                row.Path__c = fit(payload.path, 255);
            }
            Datetime committedOn = parseDatetime(payload.lastCommitDate);
            row.Last_Commit_Date__c = committedOn != null ? committedOn : System.now();
            row.Last_Commit_SHA__c = fit(String.isBlank(payload.lastCommitSha) ? sha : payload.lastCommitSha, 40);
            if (isNew) {
                inserts.add(row);
            } else {
                updates.add(row);
            }
        }
        insert inserts;
        update updates;
        return inserts.size() + updates.size();
    }

    private static void handlePullRequest(Context ctx) {
        resolveWorkItem(ctx, true);
        CDO_CallbackResource.CallbackRequest req = ctx.req;
        CDO_Work_Item__c wi = ctx.workItem;
        if (ctx.status == FAILED || ctx.status == CANCELLED) {
            ctx.summary = 'Pull request for ' + wi.Name + ' was not opened' +
                (String.isBlank(req.message) ? '.' : ': ' + req.message.trim());
            return;
        }
        CDO_Work_Item__c upd = new CDO_Work_Item__c(Id = wi.Id);
        if (url(req.pullRequestUrl) != null) {
            upd.Pull_Request_URL__c = url(req.pullRequestUrl);
        }
        if (req.pullRequestNumber != null) {
            upd.Pull_Request_Number__c = req.pullRequestNumber;
        }
        if (!CLOSED_ITEMS.contains(wi.Status__c)) {
            upd.Status__c = 'In_Review';
        }
        update upd;
        ctx.summary = 'Pull request ' + (req.pullRequestNumber == null ? '' : '#' + req.pullRequestNumber + ' ') +
            'recorded for ' + wi.Name + '.';
    }

    private static void handleValidation(Context ctx) {
        requireStatus(ctx);
        resolveWorkItem(ctx, true);
        resolveStage(ctx);
        CDO_CallbackResource.CallbackRequest req = ctx.req;
        CDO_Work_Item__c wi = ctx.workItem;
        ctx.checkOnly = true;
        recordDeployment(ctx, 'Validation');
        CDO_Work_Item__c upd = new CDO_Work_Item__c(Id = wi.Id, Last_Validation_Status__c = validationStatus(ctx.status));
        if (req.coveragePercent != null) {
            upd.Last_Coverage__c = percent(req.coveragePercent);
        }
        if (req.testsPassed != null) {
            upd.Last_Tests_Passed__c = req.testsPassed;
        }
        if (url(req.runUrl) != null) {
            upd.Last_Run_URL__c = url(req.runUrl);
        }
        update upd;
        Integer findings = recordFindings(ctx);
        ctx.summary = 'Validation ' + ctx.status + ' for ' + wi.Name + ' on ' + stageLabel(ctx) +
            (req.coveragePercent == null ? '' : ', coverage ' + percent(req.coveragePercent) + '%') +
            (findings == 0 ? '' : ', ' + findings + ' finding' + (findings == 1 ? '' : 's')) + '.';
        if (ctx.status != RUNNING) {
            ctx.notifyCategory = 'Validation';
        }
    }

    private static Integer recordFindings(Context ctx) {
        List<CDO_CallbackResource.FindingPayload> findings = ctx.req.findings;
        if (findings == null || findings.isEmpty()) {
            return 0;
        }
        Id depId = ctx.deployment == null ? null : ctx.deployment.Id;
        if (depId != null) {
            // Findings belong to the deployment: a resent callback replaces them instead of doubling them.
            delete [SELECT Id FROM CDO_Scan_Finding__c WHERE Deployment__c = :depId];
        }
        List<CDO_Scan_Finding__c> rows = new List<CDO_Scan_Finding__c>();
        for (CDO_CallbackResource.FindingPayload f : findings) {
            if (f == null || rows.size() >= MAX_FINDINGS) {
                continue;
            }
            String file = String.isBlank(f.file) ? null : f.file.trim();
            if (file != null && file.length() > 255) {
                file = file.right(255);
            }
            rows.add(
                new CDO_Scan_Finding__c(
                    Work_Item__c = ctx.workItem == null ? null : ctx.workItem.Id,
                    Deployment__c = depId,
                    Tool__c = normalizeTool(f.tool),
                    Rule__c = fit(f.rule, 255),
                    Severity__c = normalizeSeverity(f.severity),
                    File__c = file,
                    Line__c = f.line,
                    Message__c = fit(f.message, LONG_TEXT)
                )
            );
        }
        insert rows;
        return rows.size();
    }

    private static void handleApproval(Context ctx) {
        resolveWorkItem(ctx, ctx.promotion == null);
        if (ctx.stage == null) {
            resolveStage(ctx);
        }
        CDO_CallbackResource.CallbackRequest req = ctx.req;
        String review = normalizeReviewState(req.reviewState);
        Boolean approved = req.pullRequestsApproved == true || review == 'Approved';
        String decision;
        if (approved) {
            decision = 'Approved';
        } else if (review == 'Changes_Requested') {
            decision = 'Rejected';
        } else if (ctx.status == CANCELLED || isDismissal(req.reviewState)) {
            decision = 'Removed';
        }
        insert new CDO_Approval__c(
            Work_Item__c = ctx.workItem == null ? null : ctx.workItem.Id,
            Promotion__c = ctx.promotion == null ? null : ctx.promotion.Id,
            Stage__c = ctx.stage == null ? null : ctx.stage.Id,
            Approver__c = fit(req.approver, 255),
            Method__c = normalizeMethod(req.approvalMethod),
            Decision__c = decision,
            Decided_On__c = decision == null ? null : System.now(),
            Comments__c = fit(req.message, LONG_TEXT),
            Source_URL__c = url(String.isNotBlank(req.pullRequestUrl) ? req.pullRequestUrl : req.runUrl)
        );
        if (ctx.workItem != null) {
            CDO_Work_Item__c wi = ctx.workItem;
            CDO_Work_Item__c upd = new CDO_Work_Item__c(Id = wi.Id);
            if (req.pullRequestsApproved != null) {
                upd.Pull_Requests_Approved__c = req.pullRequestsApproved;
            } else if (review != null) {
                upd.Pull_Requests_Approved__c = approved;
            }
            if (review != null) {
                upd.Review_State__c = review;
            } else if (approved) {
                upd.Review_State__c = 'Approved';
            }
            if (approved && (wi.Status__c == null || PRE_APPROVAL.contains(wi.Status__c))) {
                upd.Status__c = 'Approved';
            }
            update upd;
        }
        String subject = ctx.workItem != null ? ctx.workItem.Name : ctx.promotion.Name;
        ctx.summary = (decision == null ? 'Review update' : decision) + ' for ' + subject +
            (String.isBlank(req.approver) ? '' : ' by ' + req.approver.trim()) + '.';
        ctx.notifyCategory = 'Approval';
    }

    private static void handleDeploy(Context ctx) {
        requireStatus(ctx);
        resolveWorkItem(ctx, false);
        resolveStage(ctx);
        String et = ctx.eventType;
        ctx.checkOnly = ctx.req.checkOnly == true;
        if ((et == 'Deploy' || et == 'QuickDeploy') && !ctx.checkOnly && ctx.workItem != null && isEntryStage(ctx.stage)) {
            entryHop(ctx);
            return;
        }
        if (et == 'Data') {
            updateDataSet(ctx);
        }
        recordDeployment(ctx, et);
        if (et != 'Data') {
            updateEnvironmentHealth(ctx);
        }
        ctx.summary = et + ' ' + ctx.status + ' on ' + stageLabel(ctx) +
            (ctx.workItem == null ? '' : ' for ' + ctx.workItem.Name) + '.';
        if (ctx.status != RUNNING) {
            ctx.notifyCategory = 'Deploy';
        }
    }

    /**
     * The entry hop: sf-int-deploy reports a deploy for a work item at the entry stage with no
     * promotion id. The hub owns that promotion. It is created with its junction row first, and the
     * event is then applied to it like any other promotion event, so a later Success resolves it.
     */
    private static void entryHop(Context ctx) {
        CDO_CallbackResource.CallbackRequest req = ctx.req;
        CDO_Work_Item__c wi = ctx.workItem;
        CDO_Stage__c entry = ctx.stage;
        CDO_Promotion__c existing = findEntryPromotion(ctx);
        Id promotionId;
        if (existing == null) {
            CDO_Promotion__c p = new CDO_Promotion__c(
                Project__c = wi.Project__c != null ? wi.Project__c : entry.Project__c,
                Source_Stage__c = wi.Current_Stage__c == entry.Id ? null : wi.Current_Stage__c,
                Target_Stage__c = entry.Id,
                Direction__c = 'Forward',
                Status__c = 'Deploying',
                Target_Branch__c = fit(entry.Branch__c, 255),
                Check_Only__c = false,
                Test_Level__c = normalizeTestLevel(req.testLevel),
                Workflow_Run_URL__c = url(req.runUrl),
                Promotion_Branch__c = fit(req.promotionBranch, 255),
                Target_SHA_At_Cut__c = fit(req.targetShaAtCut, 40),
                Message__c = 'Entry-hop promotion started by the approval of ' +
                    (req.pullRequestNumber == null ? 'the pull request.' : 'pull request #' + req.pullRequestNumber + '.')
            );
            insert p;
            insert CDOPromotionDispatcher.junctionRows(p.Id, new List<CDO_Work_Item__c>{ wi });
            promotionId = p.Id;
            ctx.notes.add('Created the entry-hop promotion for ' + wi.Name + ' together with its promoted-work-item row.');
        } else {
            promotionId = existing.Id;
            Integer linked = [
                SELECT COUNT() FROM CDO_Promoted_Work_Item__c WHERE Promotion__c = :promotionId AND Work_Item__c = :wi.Id
            ];
            if (linked == 0) {
                insert CDOPromotionDispatcher.junctionRows(promotionId, new List<CDO_Work_Item__c>{ wi });
                ctx.notes.add('Junction row added for ' + wi.Name + '.');
            }
        }
        req.promotionId = String.valueOf(promotionId);
        applyPromotion(ctx);
    }

    /** Same run URL first; else the open (Dispatched/Deploying) promotion for this work item and stage. */
    private static CDO_Promotion__c findEntryPromotion(Context ctx) {
        Id stageId = ctx.stage.Id;
        Id wiId = ctx.workItem.Id;
        String runUrl = url(ctx.req.runUrl);
        if (runUrl != null) {
            List<CDO_Promotion__c> byRun = [
                SELECT Id FROM CDO_Promotion__c
                WHERE Workflow_Run_URL__c = :runUrl AND Target_Stage__c = :stageId
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 1
            ];
            if (!byRun.isEmpty()) {
                return byRun[0];
            }
        }
        List<CDO_Promotion__c> open = [
            SELECT Id FROM CDO_Promotion__c
            WHERE Target_Stage__c = :stageId
                AND Status__c IN :CDOPromotionDispatcher.IN_FLIGHT_STATUSES
                AND Id IN (SELECT Promotion__c FROM CDO_Promoted_Work_Item__c WHERE Work_Item__c = :wiId)
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        return open.isEmpty() ? null : open[0];
    }

    /** A data deploy names its CDO_Data_Set__c in deploymentId (the hub created that row). */
    private static void updateDataSet(Context ctx) {
        Id dataSetId = toIdOrNull(ctx.req.deploymentId, CDO_Data_Set__c.SObjectType);
        if (dataSetId == null) {
            return;
        }
        CDO_Data_Set__c ds = new CDO_Data_Set__c(Id = dataSetId);
        if (ctx.status == RUNNING) {
            ds.Status__c = 'Deploying';
        } else if (ctx.status == SUCCESS) {
            ds.Status__c = 'Deployed';
            ds.Last_Deployed_On__c = System.now();
        } else if (ctx.status == FAILED) {
            ds.Status__c = 'Failed';
        }
        if (url(ctx.req.runUrl) != null) {
            ds.Last_Run_URL__c = url(ctx.req.runUrl);
        }
        Database.SaveResult sr = Database.update(ds, false);
        if (!sr.isSuccess()) {
            ctx.notes.add('Data set ' + dataSetId + ' was not updated: ' + sr.getErrors());
        }
    }

    /** sf-conflict-check: flag the overlapping components; a clean result clears this work item's flags. */
    private static void handleConflictCheck(Context ctx) {
        resolveWorkItem(ctx, true);
        CDO_CallbackResource.CallbackRequest req = ctx.req;
        CDO_Work_Item__c wi = ctx.workItem;
        Id wiId = wi.Id;
        List<String> paths = splitLines(req.conflictPaths);
        Set<String> pathSet = new Set<String>(paths);
        Set<String> overlap = new Set<String>();
        if (req.components != null) {
            for (CDO_CallbackResource.ComponentPayload c : req.components) {
                if (c == null) {
                    continue;
                }
                if (String.isNotBlank(c.uniqueId)) {
                    overlap.add(c.uniqueId.trim().toLowerCase());
                } else if (String.isNotBlank(c.type) && String.isNotBlank(c.name)) {
                    overlap.add((c.type.trim() + ':' + c.name.trim()).toLowerCase());
                }
                if (String.isNotBlank(c.path)) {
                    pathSet.add(c.path.trim());
                }
            }
        }
        List<CDO_Component__c> own = [
            SELECT Id, Unique_ID__c, Path__c, Has_Conflict__c FROM CDO_Component__c WHERE Work_Item__c = :wiId
        ];
        for (CDO_Component__c c : own) {
            if (c.Path__c != null && pathSet.contains(c.Path__c) && c.Unique_ID__c != null) {
                overlap.add(c.Unique_ID__c.toLowerCase());
            }
        }
        List<CDO_Component__c> changes = new List<CDO_Component__c>();
        for (CDO_Component__c c : own) {
            Boolean flagged = (c.Unique_ID__c != null && overlap.contains(c.Unique_ID__c.toLowerCase())) ||
                (c.Path__c != null && pathSet.contains(c.Path__c));
            if (c.Has_Conflict__c != flagged) {
                c.Has_Conflict__c = flagged;
                changes.add(c);
            }
        }
        if (!overlap.isEmpty()) {
            // The other open work items carrying the same components overlap too.
            for (CDO_Component__c c : [
                SELECT Id FROM CDO_Component__c
                WHERE Unique_ID__c IN :overlap AND Work_Item__c != :wiId AND Has_Conflict__c = false
                    AND Work_Item__r.Status__c NOT IN :CLOSED_ITEMS
                LIMIT 2000
            ]) {
                c.Has_Conflict__c = true;
                changes.add(c);
            }
        }
        update changes;
        update new CDO_Work_Item__c(Id = wiId, Conflict_Paths__c = paths.isEmpty() ? null : fit(req.conflictPaths, LONG_TEXT));
        Boolean clean = paths.isEmpty() && overlap.isEmpty();
        ctx.summary = clean
            ? 'No overlapping components for ' + wi.Name + '.'
            : 'Overlap found for ' + wi.Name + describePaths(paths);
        if (!clean) {
            ctx.notifyCategory = 'Conflict';
        }
    }

    private static void handleMerge(Context ctx) {
        resolveWorkItem(ctx, true);
        if (ctx.status == SUCCESS) {
            update new CDO_Work_Item__c(Id = ctx.workItem.Id, Merge_State__c = 'Merged');
        }
        ctx.summary = 'Merge ' + (ctx.status == null ? 'event' : ctx.status) + ' for ' + ctx.workItem.Name + '.';
    }

    private static void handleUnknown(Context ctx) {
        resolveWorkItem(ctx, false);
        ctx.summary = 'Event type "' + ctx.eventType + '" is not handled by this hub version; it was recorded in the audit trail only.';
    }

    // ---- Release events --------------------------------------------------------------------------

    private static void applyRelease(Context ctx) {
        CDO_CallbackResource.CallbackRequest req = ctx.req;
        Id releaseId = toId(req.releaseId, CDO_Release__c.SObjectType, 'releaseId');
        List<CDO_Release__c> rows = [SELECT Id, Name, Status__c, Project__c FROM CDO_Release__c WHERE Id = :releaseId];
        if (rows.isEmpty()) {
            throw new CallbackException('Unknown release ' + req.releaseId + '.');
        }
        ctx.release = rows[0];
        if (ctx.projectId == null) {
            ctx.projectId = ctx.release.Project__c;
        }
        requireStatus(ctx);
        if (ctx.eventType == null) {
            ctx.eventType = 'Release';
        }
        String et = ctx.eventType;
        resolveWorkItem(ctx, false);
        resolveStage(ctx);
        if (ctx.stage == null) {
            ctx.stage = productionStage(ctx.projectId);
            ctx.environmentId = ctx.stage == null ? null : ctx.stage.Environment__c;
        }
        ctx.checkOnly = et == 'Validation' || req.checkOnly == true;
        Boolean assembly = et == 'Merge' || et == 'Commit';
        String target = releaseStatus(ctx.status, ctx.checkOnly, assembly);
        Boolean wasReleased = ctx.release.Status__c == 'Released';

        CDO_Release__c r = new CDO_Release__c(Id = ctx.release.Id);
        if (target != null && !(wasReleased && target != 'Released')) {
            r.Status__c = target;
        }
        if (String.isNotBlank(req.promotionBranch)) {
            r.Release_Branch__c = fit(req.promotionBranch, 255);
        }
        if (url(req.runUrl) != null) {
            r.Workflow_Run_URL__c = url(req.runUrl);
        }
        if (ctx.checkOnly && ctx.status == SUCCESS && String.isNotBlank(req.deployId)) {
            r.Validated_Deploy_Id__c = fit(req.deployId, 18);
        }
        // The contract has no tag or release-URL field: a Release event carries the GitHub release
        // page in pullRequestUrl (https://github.com/{owner}/{repo}/releases/tag/{tag}).
        String releaseUrl = url(req.pullRequestUrl);
        if (releaseUrl != null && releaseUrl.contains('/releases/')) {
            r.Release_URL__c = releaseUrl;
            String tag = releaseUrl.substringAfter('/releases/tag/');
            if (String.isNotBlank(tag)) {
                r.Tag__c = fit(EncodingUtil.urlDecode(tag, 'UTF-8'), 255);
            }
        }
        Boolean releasedNow = r.Status__c == 'Released' && !wasReleased;
        if (releasedNow) {
            r.Released_On__c = System.now();
        }
        update r;
        if (!assembly) {
            recordDeployment(ctx, ctx.checkOnly ? 'Validation' : (et == 'QuickDeploy' ? 'QuickDeploy' : 'Deploy'));
            updateEnvironmentHealth(ctx);
        }
        Integer moved = 0;
        if (releasedNow && ctx.stage != null && ctx.stage.Is_Production__c == true) {
            moved = moveReleaseItems(ctx.release.Id, ctx.stage.Id);
        }
        ctx.summary = ctx.release.Name + ': ' + et + ' ' + ctx.status +
            (r.Status__c == null ? '' : ', release ' + r.Status__c) +
            (moved == 0 ? '' : ', ' + moved + ' work item' + (moved == 1 ? '' : 's') + ' done') + '.';
        if (ctx.status != RUNNING) {
            ctx.notifyCategory = 'Release';
        }
    }

    private static String releaseStatus(String status, Boolean checkOnly, Boolean assembly) {
        if (status == CANCELLED) {
            return null;
        }
        if (assembly) {
            return status == RUNNING ? 'Assembling' : (status == SUCCESS ? 'Ready' : 'Failed');
        }
        if (checkOnly) {
            return status == RUNNING ? 'Validating' : (status == SUCCESS ? 'Ready' : 'Failed');
        }
        return status == RUNNING ? 'Releasing' : (status == SUCCESS ? 'Released' : 'Failed');
    }

    private static Integer moveReleaseItems(Id releaseId, Id stageId) {
        List<CDO_Work_Item__c> items = new List<CDO_Work_Item__c>();
        for (CDO_Work_Item__c wi : [SELECT Id FROM CDO_Work_Item__c WHERE Release__c = :releaseId AND Status__c != 'Cancelled']) {
            items.add(new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = stageId, Status__c = 'Done', Merge_State__c = 'Merged'));
        }
        update items;
        return items.size();
    }

    // ---- Deployments and environments --------------------------------------------------------------

    /** Finds the row (deploymentId, run URL, open Running) or inserts one, then stamps this event on it. */
    private static CDO_Deployment__c recordDeployment(Context ctx, String deploymentEventType) {
        return recordDeployment(ctx, deploymentEventType, true);
    }

    private static CDO_Deployment__c recordDeployment(Context ctx, String deploymentEventType, Boolean allowInsert) {
        CDO_CallbackResource.CallbackRequest req = ctx.req;
        CDO_Deployment__c dep = findDeployment(ctx);
        Boolean isNew = dep == null;
        if (isNew && !allowInsert) {
            return null;
        }
        if (isNew) {
            dep = new CDO_Deployment__c(Started_On__c = System.now());
        }
        String status = ctx.status == null ? RUNNING : ctx.status;
        Boolean finishedAlready = !isNew && dep.Status__c != null && dep.Status__c != RUNNING;
        // A late Running never reopens a finished row.
        if (!(finishedAlready && status == RUNNING)) {
            dep.Status__c = status;
        }
        if (ctx.workItem != null) {
            dep.Work_Item__c = ctx.workItem.Id;
        }
        if (ctx.promotion != null) {
            dep.Promotion__c = ctx.promotion.Id;
        }
        if (ctx.release != null) {
            dep.Release__c = ctx.release.Id;
        }
        if (ctx.stage != null) {
            dep.Stage__c = ctx.stage.Id;
        }
        if (ctx.environmentId != null) {
            dep.Environment__c = ctx.environmentId;
        }
        dep.Event_Type__c = pick(deploymentEventType, new List<String>{ 'Commit', 'Validation', 'Deploy', 'QuickDeploy', 'Rollback', 'Data' });
        dep.Check_Only__c = ctx.checkOnly;
        if (url(req.runUrl) != null) {
            dep.Workflow_Run_URL__c = url(req.runUrl);
        }
        if (String.isNotBlank(req.deployId)) {
            dep.Deploy_Id__c = fit(req.deployId, 18);
        }
        if (String.isNotBlank(req.commitSha)) {
            dep.Commit_SHA__c = fit(req.commitSha, 40);
        }
        if (req.coveragePercent != null) {
            dep.Coverage_Percent__c = percent(req.coveragePercent);
        }
        if (req.testsPassed != null) {
            dep.Tests_Passed__c = req.testsPassed;
        }
        if (String.isNotBlank(req.failingMethods)) {
            dep.Failing_Methods__c = fit(req.failingMethods, LONG_TEXT);
        }
        if (String.isNotBlank(req.message)) {
            dep.Message__c = fit(req.message, LONG_TEXT);
        }
        Integer count = req.componentCount != null ? req.componentCount : (req.components == null ? null : req.components.size());
        if (count != null) {
            dep.Component_Count__c = count;
        }
        if (String.isNotBlank(req.testLevel)) {
            dep.Test_Level__c = fit(req.testLevel, 40);
        }
        if (dep.Started_On__c == null) {
            dep.Started_On__c = System.now();
        }
        if (dep.Status__c != RUNNING) {
            dep.Completed_On__c = System.now();
        }
        upsert dep;
        ctx.deployment = dep;
        return dep;
    }

    /**
     * The de-dup rule. 1) the row the hub created (deploymentId); 2) the same workflow run for the same
     * stage and kind of attempt; 3) the open Running row for the same work and stage. Null = insert.
     * Scoping by stage and check-only keeps two distinct attempts in one run apart, such as a
     * production validation and the quick deploy that follows it in the same workflow run.
     */
    private static CDO_Deployment__c findDeployment(Context ctx) {
        CDO_CallbackResource.CallbackRequest req = ctx.req;
        Id depId = toIdOrNull(req.deploymentId, CDO_Deployment__c.SObjectType);
        if (depId != null) {
            List<CDO_Deployment__c> byId = [
                SELECT Id, Status__c, Started_On__c, Completed_On__c FROM CDO_Deployment__c WHERE Id = :depId
            ];
            if (!byId.isEmpty()) {
                return byId[0];
            }
        }
        Id stageId = ctx.stage == null ? null : ctx.stage.Id;
        Boolean checkOnly = ctx.checkOnly == true;
        String runUrl = url(req.runUrl);
        if (runUrl != null) {
            List<CDO_Deployment__c> byRun = [
                SELECT Id, Status__c, Started_On__c, Completed_On__c FROM CDO_Deployment__c
                WHERE Workflow_Run_URL__c = :runUrl AND Stage__c = :stageId AND Check_Only__c = :checkOnly
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 1
            ];
            if (!byRun.isEmpty()) {
                return byRun[0];
            }
        }
        List<CDO_Deployment__c> open;
        if (ctx.promotion != null) {
            Id promotionId = ctx.promotion.Id;
            open = [
                SELECT Id, Status__c, Started_On__c, Completed_On__c FROM CDO_Deployment__c
                WHERE Status__c = 'Running' AND Promotion__c = :promotionId AND Stage__c = :stageId
                    AND Check_Only__c = :checkOnly
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 1
            ];
        } else if (ctx.release != null) {
            Id releaseId = ctx.release.Id;
            open = [
                SELECT Id, Status__c, Started_On__c, Completed_On__c FROM CDO_Deployment__c
                WHERE Status__c = 'Running' AND Release__c = :releaseId AND Stage__c = :stageId
                    AND Check_Only__c = :checkOnly
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 1
            ];
        } else if (ctx.workItem != null) {
            Id wiId = ctx.workItem.Id;
            open = [
                SELECT Id, Status__c, Started_On__c, Completed_On__c FROM CDO_Deployment__c
                WHERE Status__c = 'Running' AND Work_Item__c = :wiId AND Promotion__c = null AND Stage__c = :stageId
                    AND Check_Only__c = :checkOnly
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 1
            ];
        } else {
            Id envId = ctx.environmentId;
            open = [
                SELECT Id, Status__c, Started_On__c, Completed_On__c FROM CDO_Deployment__c
                WHERE Status__c = 'Running' AND Work_Item__c = null AND Promotion__c = null AND Release__c = null
                    AND Stage__c = :stageId AND Environment__c = :envId AND Check_Only__c = :checkOnly
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 1
            ];
        }
        return open.isEmpty() ? null : open[0];
    }

    /** Healthy on a real deploy's success, Degraded on its failure. Never anything else. */
    private static void updateEnvironmentHealth(Context ctx) {
        if (ctx.environmentId == null || ctx.checkOnly) {
            return;
        }
        CDO_Environment__c env = new CDO_Environment__c(Id = ctx.environmentId);
        if (ctx.status == SUCCESS) {
            env.Health_Status__c = 'Healthy';
            env.Last_Deployed_On__c = System.now();
            if (ctx.deployment != null && ctx.deployment.Id != null) {
                env.Last_Deployment__c = ctx.deployment.Id;
            }
        } else if (ctx.status == FAILED) {
            env.Health_Status__c = 'Degraded';
        } else {
            return;
        }
        update env;
    }

    // ---- Resolution ------------------------------------------------------------------------------

    private static void resolveWorkItem(Context ctx, Boolean required) {
        if (ctx.workItem != null) {
            return;
        }
        String key = String.isBlank(ctx.req.workItem) ? null : ctx.req.workItem.trim();
        if (key == null) {
            if (required) {
                throw new CallbackException('workItem is required for a ' + ctx.eventType + ' event.');
            }
            return;
        }
        List<CDO_Work_Item__c> rows = [
            SELECT Id, Name, Status__c, Project__c, Current_Stage__c, Feature_Branch__c, Release__c
            FROM CDO_Work_Item__c
            WHERE Name = :key
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            if (required) {
                throw new CallbackException('Unknown work item ' + key + '.');
            }
            ctx.notes.add('Unknown work item ' + key + ' ignored.');
            return;
        }
        ctx.workItem = rows[0];
        if (ctx.projectId == null) {
            ctx.projectId = ctx.workItem.Project__c;
        }
    }

    private static CDO_Work_Item__c loadWorkItemById(Id workItemId) {
        List<CDO_Work_Item__c> rows = [
            SELECT Id, Name, Status__c, Project__c, Current_Stage__c, Feature_Branch__c, Release__c
            FROM CDO_Work_Item__c
            WHERE Id = :workItemId
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /** The `environment` pipeline key within the project (the work item's, else the settings default). */
    private static void resolveStage(Context ctx) {
        String key = String.isBlank(ctx.req.environment) ? null : ctx.req.environment.trim();
        if (key == null) {
            return;
        }
        Id projectId = ctx.projectId != null ? ctx.projectId : CDO_WorkItemService.defaultProjectId();
        List<CDO_Stage__c> stages;
        if (projectId != null) {
            stages = [
                SELECT Id, Name, Project__c, Environment__c, Order__c, Is_Entry__c, Is_Production__c, Pipeline_Key__c, Branch__c
                FROM CDO_Stage__c
                WHERE Pipeline_Key__c = :key AND Project__c = :projectId
                ORDER BY Order__c ASC NULLS LAST, Id ASC
                LIMIT 1
            ];
        } else {
            stages = [
                SELECT Id, Name, Project__c, Environment__c, Order__c, Is_Entry__c, Is_Production__c, Pipeline_Key__c, Branch__c
                FROM CDO_Stage__c
                WHERE Pipeline_Key__c = :key
                LIMIT 2
            ];
            if (stages.size() > 1) {
                stages.clear();
                ctx.notes.add('Environment ' + key + ' matches stages in several projects; none was chosen.');
            }
        }
        if (!stages.isEmpty()) {
            ctx.stage = stages[0];
            ctx.environmentId = ctx.stage.Environment__c;
            if (ctx.projectId == null) {
                ctx.projectId = ctx.stage.Project__c;
            }
        }
        if (ctx.environmentId == null) {
            List<CDO_Environment__c> envs = projectId != null
                ? [SELECT Id FROM CDO_Environment__c WHERE Pipeline_Key__c = :key AND Project__c = :projectId ORDER BY CreatedDate ASC, Id ASC LIMIT 1]
                : [SELECT Id FROM CDO_Environment__c WHERE Pipeline_Key__c = :key LIMIT 2];
            if (envs.size() == 1) {
                ctx.environmentId = envs[0].Id;
            }
        }
        if (ctx.stage == null && ctx.environmentId == null) {
            ctx.notes.add('Environment ' + key + ' is not known to the hub.');
        }
    }

    private static CDO_Stage__c loadStage(Id stageId) {
        if (stageId == null) {
            return null;
        }
        List<CDO_Stage__c> rows = [
            SELECT Id, Name, Project__c, Environment__c, Order__c, Is_Entry__c, Is_Production__c, Pipeline_Key__c, Branch__c
            FROM CDO_Stage__c
            WHERE Id = :stageId
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static CDO_Stage__c productionStage(Id projectId) {
        if (projectId == null) {
            return null;
        }
        List<CDO_Stage__c> rows = [
            SELECT Id, Name, Project__c, Environment__c, Order__c, Is_Entry__c, Is_Production__c, Pipeline_Key__c, Branch__c
            FROM CDO_Stage__c
            WHERE Project__c = :projectId AND Is_Production__c = true
            ORDER BY Order__c DESC NULLS LAST, Id DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /** Is_Entry__c; when no stage of the project is flagged, the lowest-ordered non-production stage. */
    private static Boolean isEntryStage(CDO_Stage__c stage) {
        if (stage == null) {
            return false;
        }
        if (stage.Is_Entry__c == true) {
            return true;
        }
        if (stage.Is_Production__c == true) {
            return false;
        }
        Id projectId = stage.Project__c;
        if ([SELECT COUNT() FROM CDO_Stage__c WHERE Project__c = :projectId AND Is_Entry__c = true] > 0) {
            return false;
        }
        List<CDO_Stage__c> first = [
            SELECT Id FROM CDO_Stage__c
            WHERE Project__c = :projectId AND Is_Production__c = false
            ORDER BY Order__c ASC NULLS LAST, Id ASC
            LIMIT 1
        ];
        return !first.isEmpty() && first[0].Id == stage.Id;
    }

    private static CDO_Promotion__c loadPromotion(Id promotionId) {
        List<CDO_Promotion__c> rows = [
            SELECT Id, Name, Status__c, Project__c, Source_Stage__c, Target_Stage__c, Check_Only__c,
                Workflow_Run_URL__c, Promotion_Branch__c, Target_SHA_At_Cut__c, Merge_SHA__c, Message__c,
                Completed_On__c
            FROM CDO_Promotion__c
            WHERE Id = :promotionId
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static List<CDO_Promoted_Work_Item__c> junction(Id promotionId) {
        return [SELECT Id, Work_Item__c, Status__c FROM CDO_Promoted_Work_Item__c WHERE Promotion__c = :promotionId];
    }

    private static void setJunctionStatus(List<CDO_Promoted_Work_Item__c> rows, String status) {
        if (rows == null || rows.isEmpty()) {
            return;
        }
        for (CDO_Promoted_Work_Item__c row : rows) {
            row.Status__c = status;
        }
        update rows;
    }

    private static Set<Id> workItemIds(List<CDO_Promoted_Work_Item__c> rows) {
        Set<Id> ids = new Set<Id>();
        for (CDO_Promoted_Work_Item__c row : rows) {
            if (row.Work_Item__c != null) {
                ids.add(row.Work_Item__c);
            }
        }
        return ids;
    }

    private static void stampRun(CDO_Promotion__c p, CDO_CallbackResource.CallbackRequest req) {
        if (url(req.runUrl) != null) {
            p.Workflow_Run_URL__c = url(req.runUrl);
        }
        if (String.isNotBlank(req.promotionBranch)) {
            p.Promotion_Branch__c = fit(req.promotionBranch, 255);
        }
        if (String.isNotBlank(req.targetShaAtCut)) {
            p.Target_SHA_At_Cut__c = fit(req.targetShaAtCut, 40);
        }
    }

    // ---- Response, audit, notification ----------------------------------------------------------

    private static CDO_CallbackResource.CallbackResponse finish(Context ctx) {
        CDO_CallbackResource.CallbackRequest req = ctx.req;
        String summary = String.isNotBlank(ctx.summary)
            ? ctx.summary
            : (ctx.eventType == null ? 'Event' : ctx.eventType) + (ctx.status == null ? '' : ' ' + ctx.status) + ' recorded.';
        Map<String, Id> refs = new Map<String, Id>();
        if (ctx.workItem != null) {
            refs.put('workItem', ctx.workItem.Id);
        }
        if (ctx.promotion != null) {
            refs.put('promotion', ctx.promotion.Id);
        }
        if (ctx.deployment != null && ctx.deployment.Id != null) {
            refs.put('deployment', ctx.deployment.Id);
        }
        if (ctx.release != null) {
            refs.put('release', ctx.release.Id);
        }
        String details = JSON.serializePretty(req, true);
        if (!ctx.notes.isEmpty()) {
            details = String.join(ctx.notes, '\n') + '\n\n' + details;
        }
        CDO_Audit_Event__c ev = CDO_Audit.build(
            'Callback.' + (ctx.eventType == null ? 'Unknown' : ctx.eventType) + (ctx.status == null ? '' : '.' + ctx.status),
            summary,
            details,
            refs
        );
        ev.Run_URL__c = url(req.runUrl);
        CDO_Audit.log(ev);
        if (ctx.notifyCategory != null) {
            CDO_NotificationService.notify(
                ctx.notifyCategory,
                summary,
                new Map<String, Object>{
                    'eventType' => ctx.eventType,
                    'status' => ctx.status,
                    'summary' => summary,
                    'workItem' => ctx.workItem == null ? null : ctx.workItem.Name,
                    'promotion' => ctx.promotion == null ? null : ctx.promotion.Name,
                    'release' => ctx.release == null ? null : ctx.release.Name,
                    'environment' => req.environment,
                    'runUrl' => req.runUrl,
                    'message' => req.message
                }
            );
        }
        String depId = ctx.deployment == null || ctx.deployment.Id == null ? null : String.valueOf(ctx.deployment.Id);
        return new CDO_CallbackResource.CallbackResponse(true, depId, summary);
    }

    // ---- Normalisation helpers (public: the reconciler and the tests use them) -------------------

    public static String normalizeStatus(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String k = squash(raw);
        if (RUNNING_WORDS.contains(k)) {
            return RUNNING;
        }
        if (SUCCESS_WORDS.contains(k)) {
            return SUCCESS;
        }
        if (FAILED_WORDS.contains(k)) {
            return FAILED;
        }
        if (CANCELLED_WORDS.contains(k)) {
            return CANCELLED;
        }
        throw new CallbackException('Unknown status "' + raw + '". Use Running, Success, Failed or Cancelled.');
    }

    /** The canonical event type, or the trimmed raw value when it is not one this hub knows. */
    public static String normalizeEventType(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String known = pick(raw, EVENT_TYPES);
        if (known != null) {
            return known;
        }
        String k = squash(raw);
        if (k == 'pr') {
            return 'PullRequest';
        }
        if (k == 'validate' || k == 'checkonly') {
            return 'Validation';
        }
        if (k == 'deployment') {
            return 'Deploy';
        }
        return raw.trim();
    }

    public static String normalizeTestLevel(String raw) {
        return pick(raw, TEST_LEVELS);
    }

    public static String normalizeReviewState(String raw) {
        String k = squash(raw);
        if (k == 'commented' || k == 'dismissed') {
            return 'Pending';
        }
        return pick(raw, new List<String>{ 'Pending', 'Approved', 'Changes_Requested' });
    }

    public static String normalizeMethod(String raw) {
        if (squash(raw) == 'env') {
            return 'Environment';
        }
        return pick(raw, new List<String>{ 'Review', 'Label', 'Manual', 'Environment' });
    }

    public static String normalizeAction(String raw) {
        String k = squash(raw);
        if (k == '') {
            return null;
        }
        if (new Set<String>{ 'a', 'add', 'added', 'new', 'create', 'created' }.contains(k)) {
            return 'Add';
        }
        if (new Set<String>{ 'm', 'modify', 'modified', 'changed', 'change', 'update', 'updated' }.contains(k)) {
            return 'Modify';
        }
        if (new Set<String>{ 'd', 'delete', 'deleted', 'removed', 'remove', 'destructive' }.contains(k)) {
            return 'Delete';
        }
        if (new Set<String>{ 'r', 'retrieve', 'retrieved' }.contains(k)) {
            return 'Retrieve';
        }
        return null;
    }

    public static String normalizeTool(String raw) {
        String k = squash(raw);
        if (k.contains('pmd') || k.contains('codeanalyzer')) {
            return 'PMD';
        }
        if (k.contains('sonar')) {
            return 'Sonar';
        }
        if (k.contains('eslint')) {
            return 'ESLint';
        }
        return null;
    }

    public static String normalizeSeverity(String raw) {
        String k = squash(raw);
        if (k == '1' || k == 'critical' || k == 'blocker') {
            return 'Critical';
        }
        if (k == '2' || k == 'high' || k == 'major' || k == 'error') {
            return 'High';
        }
        if (k == '3' || k == 'medium' || k == 'moderate' || k == 'warning' || k == 'warn') {
            return 'Medium';
        }
        if (k == '4' || k == 'low' || k == 'minor') {
            return 'Low';
        }
        if (k == '5' || k == 'info' || k == 'information' || k == 'note') {
            return 'Info';
        }
        return null;
    }

    /** A picklist value matched case-insensitively, ignoring spaces, dashes and underscores. */
    public static String pick(String raw, List<String> allowed) {
        if (String.isBlank(raw)) {
            return null;
        }
        String k = squash(raw);
        for (String a : allowed) {
            if (squash(a) == k) {
                return a;
            }
        }
        return null;
    }

    public static Datetime parseDatetime(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String v = raw.trim();
        try {
            return (Datetime) JSON.deserialize('"' + v + '"', Datetime.class);
        } catch (Exception e) {
            System.debug(LoggingLevel.FINE, 'Not an ISO-8601 datetime: ' + v);
        }
        try {
            return Datetime.valueOfGmt(v.replace('T', ' ').left(19));
        } catch (Exception e) {
            return null;
        }
    }

    public static Id toId(String value, Schema.SObjectType expected, String fieldName) {
        if (String.isBlank(value)) {
            return null;
        }
        Id result;
        try {
            result = Id.valueOf(value.trim());
        } catch (Exception e) {
            throw new CallbackException(fieldName + ' "' + value + '" is not a valid record Id.');
        }
        if (expected != null && result.getSObjectType() != expected) {
            throw new CallbackException(fieldName + ' "' + value + '" is not a ' + expected + ' Id.');
        }
        return result;
    }

    public static String componentKey(String workItemKey, String metadataType, String memberName) {
        return (workItemKey + '|' + metadataType.trim() + ':' + memberName.trim()).left(255);
    }

    private static Id toIdOrNull(String value, Schema.SObjectType expected) {
        try {
            return toId(value, expected, 'id');
        } catch (CallbackException e) {
            return null;
        }
    }

    private static void requireStatus(Context ctx) {
        if (ctx.status == null) {
            throw new CallbackException(
                'status is required for a ' + ctx.eventType + ' event (Running, Success, Failed or Cancelled).'
            );
        }
    }

    private static String validationStatus(String status) {
        if (status == RUNNING) {
            return 'Running';
        }
        if (status == SUCCESS) {
            return 'Passed';
        }
        if (status == FAILED) {
            return 'Failed';
        }
        return 'Not_Run';
    }

    /** Literal percent (87.5 means 87.5 %), kept within the field's range. */
    private static Decimal percent(Decimal value) {
        Decimal v = value < 0 ? 0 : (value > 100 ? 100 : value);
        return v.setScale(2);
    }

    private static Boolean isDismissal(String raw) {
        String k = squash(raw);
        return k.contains('dismiss') || k.contains('removed');
    }

    private static String stageLabel(Context ctx) {
        if (ctx.stage != null) {
            return ctx.stage.Name;
        }
        return String.isBlank(ctx.req.environment) ? 'an unknown environment' : ctx.req.environment.trim();
    }

    private static String describePaths(List<String> paths) {
        if (paths.isEmpty()) {
            return '.';
        }
        List<String> shown = new List<String>();
        for (Integer i = 0; i < paths.size() && i < 10; i++) {
            shown.add(paths[i]);
        }
        return ': ' + String.join(shown, ', ') + (paths.size() > 10 ? ' and ' + (paths.size() - 10) + ' more.' : '.');
    }

    private static List<String> splitLines(String value) {
        List<String> out = new List<String>();
        if (String.isBlank(value)) {
            return out;
        }
        Set<String> seen = new Set<String>();
        for (String line : value.split('\\r?\\n')) {
            String t = line.trim();
            if (String.isNotBlank(t) && seen.add(t)) {
                out.add(t);
            }
        }
        return out;
    }

    private static String firstLine(String value) {
        return String.isBlank(value) ? '' : value.trim().substringBefore('\n').trim();
    }

    private static String squash(String value) {
        return value == null ? '' : value.replaceAll('[^A-Za-z0-9]', '').toLowerCase();
    }

    private static String fit(String value, Integer maxLength) {
        if (String.isBlank(value)) {
            return null;
        }
        String v = value.trim();
        return v.length() > maxLength ? v.left(maxLength) : v;
    }

    /** A URL that fits a Url field, or null: a truncated URL is a broken link. */
    private static String url(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String v = value.trim();
        return v.length() > 255 ? null : v;
    }
}
