/**
 * Promotions from the UI: promote a single work item (cdoPromoteAction / cdoPromoteDeployAction,
 * the story board), build a multi-item promotion (cdoPromote), deploy or cancel a Draft, and read
 * a promotion with its junction rows and deployments.
 *
 * Every promotion goes through CDOPromotionDispatcher.requestPromotion, which writes the
 * CDO_Promoted_Work_Item__c junction rows and queues the dispatch. Self-service gate: promoting
 * into the entry stage needs the CDO_Approve_Entry permission or an approved pull request.
 *
 * The same rules as CDOWorkItemCommandCenter apply, so every entry point agrees: production ships
 * through a release (never a promotion), a work item needs a commit before it is promoted, and a
 * promotion is not dispatched while a work item's coverage is below its minimum (a Draft may still
 * be created; approving it holds it until coverage is raised).
 */
public with sharing class PromotionController {

    public static final Set<String> OPEN_PROMOTION = new Set<String>{ 'Draft', 'Queued', 'Dispatched', 'Deploying' };
    public static final String PRODUCTION_MESSAGE =
        'Production ships through a release, not a promotion. Add the work items to a release on the Release Board, ' +
        'assemble it, then use Release to Production.';
    private static final Set<String> TEST_LEVELS = new Set<String>{ 'NoTestRun', 'RunSpecifiedTests', 'RunLocalTests', 'RunAllTestsInOrg' };
    private static final Set<String> OPTION_KEYS = new Set<String>{ 'testLevel', 'specifiedTests', 'checkOnly', 'allowDestructive', 'direction' };

    // Two @AuraEnabled methods may not share a name, so both actions wrap one private method.

    /** Promote the work item to its next stage and dispatch the deploy (queued in Apex). */
    @AuraEnabled
    public static PromotionResult promoteWorkItem(Id workItemId) {
        return promote(workItemId, true);
    }

    /** Create a Draft promotion to the next stage without dispatching it. */
    @AuraEnabled
    public static PromotionResult promoteWorkItemOnly(Id workItemId) {
        return promote(workItemId, false);
    }

    private static PromotionResult promote(Id workItemId, Boolean deploy) {
        if (workItemId == null) {
            throw fail('Open a work item to promote it.');
        }
        try {
            CDO_Work_Item__c wi = loadWorkItems(new List<Id>{ workItemId })[0];
            if (PipelineController.CLOSED_WORK_ITEM.contains(wi.Status__c)) {
                throw fail(wi.Name + ' is ' + wi.Status__c.replace('_', ' ') + ' and cannot be promoted.');
            }
            if (wi.Project__c == null) {
                throw fail(wi.Name + ' has no project, so it has no pipeline to move through. Set its Project first.');
            }
            CDO_Stage__c next = CDO_WorkItemService.nextStage(workItemId);
            if (next == null) {
                throw fail(wi.Name + ' is already at production. There is nothing further to promote it to.');
            }
            CDO_Stage__c target = loadStage(next.Id);
            List<CDO_Work_Item__c> items = new List<CDO_Work_Item__c>{ wi };
            assertPromotable(target, items, deploy);
            assertEntryGate(target, items);
            assertNotAlreadyPromoting(items, target.Id);

            Map<String, String> options = new Map<String, String>{ 'direction' => 'Forward' };
            if (String.isNotBlank(wi.Test_Level_Override__c)) {
                options.put('testLevel', wi.Test_Level_Override__c);
            }
            if (String.isNotBlank(wi.Specified_Tests__c)) {
                options.put('specifiedTests', wi.Specified_Tests__c);
            }
            Id promotionId = CDOPromotionDispatcher.requestPromotion(new List<Id>{ workItemId }, target.Id, options, deploy);
            return buildResult(promotionId, deploy);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw fail('Could not promote the work item: ' + messageOf(e));
        }
    }

    /**
     * Promote several work items into one target stage. Forward promotions take work items whose
     * current stage is the stage before the target (for the entry stage: Approved work items with
     * no stage). options keys: testLevel, specifiedTests, checkOnly, allowDestructive, direction.
     */
    @AuraEnabled
    public static PromotionResult createPromotion(List<Id> workItemIds, Id targetStageId, Boolean deploy, Map<String, String> options) {
        if (workItemIds == null || workItemIds.isEmpty()) {
            throw fail('Select at least one work item to promote.');
        }
        if (targetStageId == null) {
            throw fail('Choose the stage to promote into.');
        }
        try {
            Map<String, String> opts = cleanOptions(options);
            CDO_Stage__c target = loadStage(targetStageId);
            List<CDO_Stage__c> ordered = PipelineController.orderedStages(target.Project__c);
            List<CDO_Work_Item__c> items = loadWorkItems(new List<Id>(new Set<Id>(workItemIds)));
            assertPromotable(target, items, deploy == true);
            if (opts.get('direction') == 'Back') {
                assertBackCandidates(items, target, ordered);
            } else {
                assertForwardCandidates(items, target, ordered);
                assertEntryGate(target, items);
            }
            assertNotAlreadyPromoting(items, target.Id);
            List<Id> ids = new List<Id>();
            for (CDO_Work_Item__c wi : items) {
                ids.add(wi.Id);
            }
            Boolean dispatchNow = deploy == true;
            Id promotionId = CDOPromotionDispatcher.requestPromotion(ids, target.Id, opts, dispatchNow);
            return buildResult(promotionId, dispatchNow);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw fail('Could not create the promotion: ' + messageOf(e));
        }
    }

    /** Dispatch a Draft promotion (Draft → Queued, then the dispatcher sends the next one). */
    @AuraEnabled
    public static PromotionResult deployPromotion(Id promotionId) {
        CDO_Promotion__c p = loadPromotion(promotionId);
        if (p.Status__c != 'Draft') {
            throw fail(p.Name + ' is ' + p.Status__c + '. Only a Draft promotion can be deployed.');
        }
        List<CDO_Work_Item__c> items = new List<CDO_Work_Item__c>();
        for (CDO_Promoted_Work_Item__c j : p.Promoted_Work_Items__r) {
            items.add(j.Work_Item__r);
        }
        if (items.isEmpty()) {
            throw fail(p.Name + ' carries no work items. Cancel it and promote again.');
        }
        CDO_Stage__c target = loadStage(p.Target_Stage__c);
        assertPromotable(target, items, true);
        if (p.Direction__c != 'Back') {
            assertEntryGate(target, items);
        }
        try {
            CDOPromotionDispatcher.dispatchPromotion(p.Id);
            return buildResult(p.Id, true);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw fail('Could not deploy ' + p.Name + ': ' + messageOf(e));
        }
    }

    /**
     * Cancel a promotion that has not started running. A Dispatched promotion without a run URL
     * can be cancelled too: only the callback proves a workflow started.
     */
    @AuraEnabled
    public static PromotionResult cancelPromotion(Id promotionId) {
        CDO_Promotion__c p = loadPromotion(promotionId);
        if (!canCancel(p)) {
            if (PipelineController.IN_FLIGHT_PROMOTION.contains(p.Status__c) && String.isNotBlank(p.Workflow_Run_URL__c)) {
                throw fail(p.Name + ' is running in GitHub. Cancel the workflow run at ' + p.Workflow_Run_URL__c +
                    '; its callback will update this promotion.');
            }
            throw fail(p.Name + ' is ' + p.Status__c + ' and can no longer be cancelled.');
        }
        Boolean wasInQueue = p.Status__c != 'Draft';
        try {
            update new CDO_Promotion__c(
                Id = p.Id,
                Status__c = 'Cancelled',
                Completed_On__c = System.now(),
                Message__c = 'Cancelled by ' + UserInfo.getName() + ' (was ' + p.Status__c + ').'
            );
            CDO_Audit.log(
                'Promotion',
                (p.Name + ' cancelled by ' + UserInfo.getName()).abbreviate(255),
                'Status before cancel: ' + p.Status__c,
                new Map<String, Id>{ 'promotion' => p.Id }
            );
            if (wasInQueue) {
                // Free the stage so the next queued promotion is dispatched.
                CDOPromotionDispatcher.onPromotionFinished(p.Id);
            }
            return buildResult(p.Id, false);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw fail('Could not cancel ' + p.Name + ': ' + messageOf(e));
        }
    }

    @AuraEnabled(cacheable=true)
    public static PromotionView getPromotion(Id promotionId) {
        CDO_Promotion__c p = loadPromotion(promotionId);
        PromotionView view = new PromotionView();
        view.promotion = p;
        view.id = p.Id;
        view.name = p.Name;
        view.status = p.Status__c;
        view.direction = p.Direction__c;
        view.sourceStageName = p.Source_Stage__r?.Name;
        view.targetStageId = p.Target_Stage__c;
        view.targetStageName = p.Target_Stage__r?.Name;
        view.runUrl = p.Workflow_Run_URL__c;
        view.message = p.Message__c;
        view.isEntry = p.Target_Stage__r?.Is_Entry__c == true;
        view.canDeploy = p.Status__c == 'Draft';
        view.canCancel = canCancel(p);
        view.inFlight = PipelineController.IN_FLIGHT_PROMOTION.contains(p.Status__c);
        for (CDO_Promoted_Work_Item__c j : p.Promoted_Work_Items__r) {
            view.workItems.add(new JunctionRow(j));
        }
        for (CDO_Deployment__c d : [
            SELECT Id, Name, Status__c, Event_Type__c, Check_Only__c, Workflow_Run_URL__c, Coverage_Percent__c,
                   Tests_Passed__c, Completed_On__c, CreatedDate, Message__c, Work_Item__c, Work_Item__r.Name,
                   Promotion__c, Promotion__r.Name, Release__r.Name
            FROM CDO_Deployment__c
            WHERE Promotion__c = :p.Id
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 100
        ]) {
            view.deployments.add(new PipelineController.DeploymentSummary(d));
        }
        view.approvals = GovernanceController.getApprovals(p.Id);
        return view;
    }

    /** Work items that can be promoted into the target stage, with the reason any are not eligible. */
    @AuraEnabled(cacheable=true)
    public static CandidateView getPromotionCandidates(Id targetStageId) {
        CandidateView view = new CandidateView();
        if (targetStageId == null) {
            return view;
        }
        CDO_Stage__c target = loadStage(targetStageId);
        List<CDO_Stage__c> ordered = PipelineController.orderedStages(target.Project__c);
        CDO_Stage__c entry = PipelineController.entryStage(ordered);
        CDO_Stage__c previous = PipelineController.previousStage(target.Id, ordered);
        view.targetStageId = target.Id;
        view.targetStageName = target.Name;
        view.isEntry = entry != null && entry.Id == target.Id;
        view.previousStageId = view.isEntry ? null : previous?.Id;
        view.previousStageName = view.isEntry ? null : previous?.Name;
        view.canApproveEntry = GovernanceController.hasPermission(GovernanceController.PERM_APPROVE_ENTRY);
        view.isProduction = target.Is_Production__c == true;
        if (view.isProduction) {
            view.message = PRODUCTION_MESSAGE;
            return view;
        }

        List<CDO_Work_Item__c> items;
        if (view.isEntry) {
            Id projectId = target.Project__c;
            items = [
                SELECT Id, Name, Subject__c, Status__c, Pull_Requests_Approved__c, Pull_Request_URL__c, Last_Commit_SHA__c,
                       Last_Coverage__c, Minimum_Coverage__c, Developer__r.Name, Release__r.Name, Current_Stage__r.Name
                FROM CDO_Work_Item__c
                WHERE Current_Stage__c = null AND Status__c = 'Approved'
                      AND (Project__c = :projectId OR Project__c = null)
                ORDER BY Name
                LIMIT 500
            ];
        } else if (previous != null) {
            Id previousId = previous.Id;
            items = [
                SELECT Id, Name, Subject__c, Status__c, Pull_Requests_Approved__c, Pull_Request_URL__c, Last_Commit_SHA__c,
                       Last_Coverage__c, Minimum_Coverage__c, Developer__r.Name, Release__r.Name, Current_Stage__r.Name
                FROM CDO_Work_Item__c
                WHERE Current_Stage__c = :previousId AND Status__c NOT IN :PipelineController.CLOSED_WORK_ITEM
                ORDER BY Name
                LIMIT 500
            ];
        } else {
            items = new List<CDO_Work_Item__c>();
        }

        Map<Id, String> openPromotions = openPromotionsByWorkItem(items, target.Id);
        Set<Id> withCommits = idsWithCommits(items);
        for (CDO_Work_Item__c wi : items) {
            Candidate c = new Candidate(wi);
            if (openPromotions.containsKey(wi.Id)) {
                c.eligible = false;
                c.reason = 'Already in ' + openPromotions.get(wi.Id);
            } else if (!withCommits.contains(wi.Id)) {
                c.eligible = false;
                c.reason = 'No commits yet';
            } else if (view.isEntry && !view.canApproveEntry && wi.Pull_Requests_Approved__c != true) {
                c.eligible = false;
                c.reason = 'Needs an approved pull request (or CDO_Approve_Entry)';
            }
            if (c.eligible) {
                view.candidates.add(c);
            } else {
                view.ineligible.add(c);
            }
        }
        return view;
    }

    /** The current project's stages, for the target-stage picker. */
    @AuraEnabled(cacheable=true)
    public static List<StageOption> getStages(Id projectId) {
        List<StageOption> options = new List<StageOption>();
        CDO_Project__c project = PipelineController.resolveProject(projectId);
        if (project == null) {
            return options;
        }
        List<CDO_Stage__c> ordered = PipelineController.orderedStages(project.Id);
        CDO_Stage__c entry = PipelineController.entryStage(ordered);
        for (CDO_Stage__c s : ordered) {
            // Production is reached through a release, so it is never a promotion target.
            if (s.Is_Production__c != true) {
                options.add(new StageOption(s, entry != null && entry.Id == s.Id));
            }
        }
        return options;
    }

    /** What promoting this work item would do, for the record-action confirmation screen. */
    @AuraEnabled(cacheable=true)
    public static PromotionPreview getPromotionPreview(Id workItemId) {
        PromotionPreview preview = new PromotionPreview();
        if (workItemId == null) {
            preview.blockedReason = 'Open a work item to promote it.';
            return preview;
        }
        CDO_Work_Item__c wi = loadWorkItems(new List<Id>{ workItemId })[0];
        preview.workItemId = wi.Id;
        preview.workItemName = wi.Name;
        preview.subject = wi.Subject__c;
        preview.status = wi.Status__c;
        preview.currentStageName = wi.Current_Stage__r?.Name;
        if (PipelineController.CLOSED_WORK_ITEM.contains(wi.Status__c)) {
            preview.blockedReason = wi.Name + ' is ' + wi.Status__c.replace('_', ' ') + ' and cannot be promoted.';
            return preview;
        }
        if (wi.Project__c == null) {
            preview.blockedReason = wi.Name + ' has no project, so it has no pipeline to move through. Set its Project first.';
            return preview;
        }
        CDO_Stage__c next;
        try {
            next = CDO_WorkItemService.nextStage(workItemId);
        } catch (Exception e) {
            preview.blockedReason = messageOf(e);
            return preview;
        }
        if (next == null) {
            preview.blockedReason = wi.Name + ' is already at production.';
            return preview;
        }
        CDO_Stage__c target = loadStage(next.Id);
        preview.nextStageId = target.Id;
        preview.nextStageName = target.Name;
        preview.isEntry = target.Is_Entry__c == true || wi.Current_Stage__c == null;
        preview.isProduction = target.Is_Production__c == true;
        List<CDO_Work_Item__c> items = new List<CDO_Work_Item__c>{ wi };
        String rule = promotableFailure(target, items, false);
        String gate = entryGateFailure(target, items);
        Map<Id, String> open = openPromotionsByWorkItem(items, target.Id);
        if (rule != null) {
            preview.blockedReason = rule;
        } else if (gate != null) {
            preview.blockedReason = gate;
        } else if (open.containsKey(wi.Id)) {
            preview.blockedReason = wi.Name + ' is already in ' + open.get(wi.Id) + '.';
        }
        preview.canPromote = preview.blockedReason == null;
        preview.deployBlockedReason = preview.canPromote ? promotableFailure(target, items, true) : null;
        preview.canDeploy = preview.canPromote && preview.deployBlockedReason == null;
        return preview;
    }

    // ----------------------------------------------------------------------------------------
    // Gates and validation
    // ----------------------------------------------------------------------------------------

    /** Throws unless the work items may be promoted into the target (rules shared with the command center). */
    private static void assertPromotable(CDO_Stage__c target, List<CDO_Work_Item__c> items, Boolean deploy) {
        String failure = promotableFailure(target, items, deploy);
        if (failure != null) {
            throw fail(failure);
        }
    }

    @TestVisible
    private static String promotableFailure(CDO_Stage__c target, List<CDO_Work_Item__c> items, Boolean deploy) {
        if (target != null && target.Is_Production__c == true) {
            return target.Name + ': ' + PRODUCTION_MESSAGE;
        }
        Set<Id> withCommits = idsWithCommits(items);
        List<String> noCommits = new List<String>();
        List<String> lowCoverage = new List<String>();
        for (CDO_Work_Item__c wi : items) {
            if (!withCommits.contains(wi.Id)) {
                noCommits.add(wi.Name);
            }
            if (deploy == true && wi.Last_Coverage__c != null && wi.Minimum_Coverage__c != null &&
                wi.Last_Coverage__c < wi.Minimum_Coverage__c) {
                lowCoverage.add(wi.Name + ' (' + wi.Last_Coverage__c.setScale(1) + '% against a minimum of ' +
                    wi.Minimum_Coverage__c.setScale(1) + '%)');
            }
        }
        if (!noCommits.isEmpty()) {
            return 'Commit changes before promoting. No commits yet: ' + String.join(noCommits, ', ') + '.';
        }
        if (!lowCoverage.isEmpty()) {
            return 'Coverage is below the minimum for ' + String.join(lowCoverage, ', ') +
                '. Raise coverage and validate again, or use Promote to create a Draft and deploy it later.';
        }
        return null;
    }

    /** Work items with at least one commit (Last_Commit_SHA__c set, or a CDO_Commit__c row). */
    private static Set<Id> idsWithCommits(List<CDO_Work_Item__c> items) {
        Set<Id> result = new Set<Id>();
        Set<Id> unknown = new Set<Id>();
        for (CDO_Work_Item__c wi : items) {
            if (wi == null) {
                continue;
            }
            if (String.isNotBlank(wi.Last_Commit_SHA__c)) {
                result.add(wi.Id);
            } else {
                unknown.add(wi.Id);
            }
        }
        if (!unknown.isEmpty()) {
            for (AggregateResult ar : [
                SELECT Work_Item__c wi FROM CDO_Commit__c WHERE Work_Item__c IN :unknown GROUP BY Work_Item__c
            ]) {
                result.add((Id) ar.get('wi'));
            }
        }
        return result;
    }

    /** Throws when the target is the entry stage and the user lacks both permission and PR approval. */
    public static void assertEntryGate(CDO_Stage__c target, List<CDO_Work_Item__c> items) {
        String failure = entryGateFailure(target, items);
        if (failure != null) {
            throw fail(failure);
        }
    }

    private static String entryGateFailure(CDO_Stage__c target, List<CDO_Work_Item__c> items) {
        if (target == null || !isEntryStage(target)) {
            return null;
        }
        if (GovernanceController.hasPermission(GovernanceController.PERM_APPROVE_ENTRY)) {
            return null;
        }
        List<String> unapproved = new List<String>();
        for (CDO_Work_Item__c wi : items) {
            if (wi.Pull_Requests_Approved__c != true) {
                unapproved.add(wi.Name);
            }
        }
        if (unapproved.isEmpty()) {
            return null;
        }
        return 'Promoting into the entry stage ' + target.Name + ' needs an approved pull request or the ' +
            GovernanceController.PERM_APPROVE_ENTRY + ' permission. Not approved yet: ' + String.join(unapproved, ', ') + '.';
    }

    private static Boolean isEntryStage(CDO_Stage__c target) {
        if (target.Is_Entry__c == true) {
            return true;
        }
        CDO_Stage__c entry = PipelineController.entryStage(PipelineController.orderedStages(target.Project__c));
        return entry != null && entry.Id == target.Id;
    }

    private static void assertForwardCandidates(List<CDO_Work_Item__c> items, CDO_Stage__c target, List<CDO_Stage__c> ordered) {
        CDO_Stage__c entry = PipelineController.entryStage(ordered);
        Boolean targetIsEntry = entry != null && entry.Id == target.Id;
        CDO_Stage__c previous = targetIsEntry ? null : PipelineController.previousStage(target.Id, ordered);
        if (!targetIsEntry && previous == null) {
            throw fail(target.Name + ' has no stage before it, so nothing can be promoted into it.');
        }
        List<String> problems = new List<String>();
        for (CDO_Work_Item__c wi : items) {
            if (PipelineController.CLOSED_WORK_ITEM.contains(wi.Status__c)) {
                problems.add(wi.Name + ' is ' + wi.Status__c);
            } else if (wi.Project__c != null && wi.Project__c != target.Project__c) {
                problems.add(wi.Name + ' belongs to another project');
            } else if (targetIsEntry && wi.Current_Stage__c != null) {
                problems.add(wi.Name + ' is already in ' + wi.Current_Stage__r.Name);
            } else if (!targetIsEntry && wi.Current_Stage__c != previous.Id) {
                problems.add(wi.Name + ' is in ' + (wi.Current_Stage__c == null ? 'no stage yet' : wi.Current_Stage__r.Name) +
                    ', not ' + previous.Name);
            }
        }
        if (!problems.isEmpty()) {
            throw fail('These work items cannot be promoted into ' + target.Name + ': ' + String.join(problems, '; ') + '.');
        }
    }

    private static void assertBackCandidates(List<CDO_Work_Item__c> items, CDO_Stage__c target, List<CDO_Stage__c> ordered) {
        Map<Id, Integer> position = new Map<Id, Integer>();
        for (Integer i = 0; i < ordered.size(); i++) {
            position.put(ordered[i].Id, i);
        }
        Integer targetPos = position.get(target.Id);
        List<String> problems = new List<String>();
        for (CDO_Work_Item__c wi : items) {
            Integer pos = wi.Current_Stage__c == null ? null : position.get(wi.Current_Stage__c);
            if (pos == null || targetPos == null || pos <= targetPos) {
                problems.add(wi.Name);
            }
        }
        if (!problems.isEmpty()) {
            throw fail('A back-promotion into ' + target.Name + ' needs work items that are already past it. Not past it: ' +
                String.join(problems, ', ') + '.');
        }
    }

    private static void assertNotAlreadyPromoting(List<CDO_Work_Item__c> items, Id targetStageId) {
        Map<Id, String> open = openPromotionsByWorkItem(items, targetStageId);
        if (open.isEmpty()) {
            return;
        }
        List<String> busy = new List<String>();
        for (CDO_Work_Item__c wi : items) {
            if (open.containsKey(wi.Id)) {
                busy.add(wi.Name + ' (' + open.get(wi.Id) + ')');
            }
        }
        throw fail('Already in an open promotion: ' + String.join(busy, ', ') +
            '. A work item can be in one open promotion at a time; let it finish, or cancel it first.');
    }

    /**
     * Work item id → "PRM-00012 (Queued)" for its open promotion. A work item may have only one open
     * promotion at a time, whatever its target (CDOPromotionDispatcher enforces the same rule).
     */
    private static Map<Id, String> openPromotionsByWorkItem(List<CDO_Work_Item__c> items, Id targetStageId) {
        Map<Id, String> open = new Map<Id, String>();
        if (items.isEmpty()) {
            return open;
        }
        Set<Id> ids = new Map<Id, CDO_Work_Item__c>(items).keySet();
        for (CDO_Promoted_Work_Item__c j : [
            SELECT Work_Item__c, Promotion__r.Name, Promotion__r.Status__c
            FROM CDO_Promoted_Work_Item__c
            WHERE Work_Item__c IN :ids AND Promotion__r.Status__c IN :OPEN_PROMOTION
            ORDER BY Promotion__r.CreatedDate DESC, Promotion__c DESC
        ]) {
            if (!open.containsKey(j.Work_Item__c)) {
                open.put(j.Work_Item__c, j.Promotion__r.Name + ' (' + j.Promotion__r.Status__c + ')');
            }
        }
        return open;
    }

    private static Map<String, String> cleanOptions(Map<String, String> options) {
        Map<String, String> clean = new Map<String, String>();
        if (options != null) {
            for (String key : options.keySet()) {
                String value = options.get(key);
                if (!OPTION_KEYS.contains(key)) {
                    throw fail('Unknown promotion option "' + key + '". Use testLevel, specifiedTests, checkOnly, allowDestructive or direction.');
                }
                if (String.isNotBlank(value)) {
                    clean.put(key, value.trim());
                }
            }
        }
        if (clean.containsKey('testLevel') && !TEST_LEVELS.contains(clean.get('testLevel'))) {
            throw fail('Test level must be one of ' + String.join(new List<String>(TEST_LEVELS), ', ') + '.');
        }
        for (String flag : new List<String>{ 'checkOnly', 'allowDestructive' }) {
            if (clean.containsKey(flag)) {
                String v = clean.get(flag).toLowerCase();
                if (v != 'true' && v != 'false') {
                    throw fail(flag + ' must be true or false.');
                }
                clean.put(flag, v);
            }
        }
        String direction = clean.containsKey('direction') ? clean.get('direction') : 'Forward';
        if (direction != 'Forward' && direction != 'Back') {
            throw fail('Direction must be Forward or Back.');
        }
        clean.put('direction', direction);
        return clean;
    }

    private static Boolean canCancel(CDO_Promotion__c p) {
        if (p.Status__c == 'Draft' || p.Status__c == 'Queued') {
            return true;
        }
        return p.Status__c == 'Dispatched' && String.isBlank(p.Workflow_Run_URL__c);
    }

    // ----------------------------------------------------------------------------------------
    // Queries
    // ----------------------------------------------------------------------------------------

    private static List<CDO_Work_Item__c> loadWorkItems(List<Id> ids) {
        List<CDO_Work_Item__c> rows = [
            SELECT Id, Name, Subject__c, Status__c, Project__c, Current_Stage__c, Current_Stage__r.Name,
                   Pull_Requests_Approved__c, Test_Level_Override__c, Specified_Tests__c, Last_Commit_SHA__c,
                   Last_Coverage__c, Minimum_Coverage__c
            FROM CDO_Work_Item__c
            WHERE Id IN :ids
            ORDER BY Name
        ];
        if (rows.size() != new Set<Id>(ids).size()) {
            throw fail('One or more work items no longer exist or you do not have access to them.');
        }
        return rows;
    }

    private static CDO_Stage__c loadStage(Id stageId) {
        List<CDO_Stage__c> rows = [
            SELECT Id, Name, Project__c, Order__c, Is_Entry__c, Is_Production__c, Gate_Type__c, Pipeline_Key__c
            FROM CDO_Stage__c
            WHERE Id = :stageId
        ];
        if (rows.isEmpty()) {
            throw fail('That stage no longer exists or you do not have access to it.');
        }
        return rows[0];
    }

    private static CDO_Promotion__c loadPromotion(Id promotionId) {
        List<CDO_Promotion__c> rows = promotionId == null ? new List<CDO_Promotion__c>() : [
            SELECT Id, Name, Status__c, Direction__c, Project__c, Project__r.Name, Source_Stage__c, Source_Stage__r.Name,
                   Target_Stage__c, Target_Stage__r.Name, Target_Stage__r.Is_Entry__c, Target_Stage__r.Is_Production__c,
                   Workflow_Run_URL__c, Promotion_Branch__c, Target_Branch__c, Merge_SHA__c, Check_Only__c, Test_Level__c,
                   Specified_Tests__c, Allow_Destructive__c, Dispatched_On__c, Completed_On__c, Message__c,
                   Requested_By__c, Requested_By__r.Name, CreatedDate,
                   (SELECT Id, Name, Status__c, Work_Item__c, Work_Item__r.Name, Work_Item__r.Subject__c,
                           Work_Item__r.Status__c, Work_Item__r.Pull_Requests_Approved__c, Work_Item__r.Current_Stage__r.Name,
                           Work_Item__r.Last_Commit_SHA__c, Work_Item__r.Last_Coverage__c, Work_Item__r.Minimum_Coverage__c
                    FROM Promoted_Work_Items__r
                    ORDER BY Work_Item__r.Name)
            FROM CDO_Promotion__c
            WHERE Id = :promotionId
        ];
        if (rows.isEmpty()) {
            throw fail('That promotion no longer exists or you do not have access to it.');
        }
        return rows[0];
    }

    private static PromotionResult buildResult(Id promotionId, Boolean dispatched) {
        CDO_Promotion__c p = [
            SELECT Id, Name, Status__c, Target_Stage__r.Name, (SELECT Id FROM Promoted_Work_Items__r)
            FROM CDO_Promotion__c
            WHERE Id = :promotionId
        ];
        PromotionResult r = new PromotionResult();
        r.promotionId = p.Id;
        r.promotionName = p.Name;
        r.status = p.Status__c;
        r.targetStageName = p.Target_Stage__r?.Name;
        r.workItemCount = p.Promoted_Work_Items__r.size();
        r.dispatched = dispatched;
        if (p.Status__c == 'Cancelled') {
            r.message = p.Name + ' cancelled.';
        } else if (p.Status__c == 'Dispatched') {
            r.message = p.Name + ' was sent to GitHub to deploy to ' + r.targetStageName +
                '. Its status updates here when the workflow reports back.';
        } else if (dispatched) {
            r.message = p.Name + ' is queued for ' + r.targetStageName +
                '. It is sent to GitHub as soon as the promotion ahead of it finishes.';
        } else {
            r.message = p.Name + ' created as a Draft for ' + r.targetStageName + '. Deploy it when it is approved.';
        }
        return r;
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

    public class PromotionResult {
        @AuraEnabled public Id promotionId;
        @AuraEnabled public String promotionName;
        @AuraEnabled public String status;
        @AuraEnabled public String targetStageName;
        @AuraEnabled public Integer workItemCount;
        @AuraEnabled public Boolean dispatched;
        @AuraEnabled public String message;
    }

    public class PromotionView {
        @AuraEnabled public CDO_Promotion__c promotion;
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String direction;
        @AuraEnabled public String sourceStageName;
        @AuraEnabled public Id targetStageId;
        @AuraEnabled public String targetStageName;
        @AuraEnabled public String runUrl;
        @AuraEnabled public String message;
        @AuraEnabled public Boolean isEntry;
        @AuraEnabled public Boolean canDeploy;
        @AuraEnabled public Boolean canCancel;
        @AuraEnabled public Boolean inFlight;
        @AuraEnabled public List<JunctionRow> workItems = new List<JunctionRow>();
        @AuraEnabled public List<PipelineController.DeploymentSummary> deployments = new List<PipelineController.DeploymentSummary>();
        @AuraEnabled public List<CDO_Approval__c> approvals = new List<CDO_Approval__c>();
    }

    public class JunctionRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public Id workItemId;
        @AuraEnabled public String workItemName;
        @AuraEnabled public String subject;
        @AuraEnabled public String workItemStatus;
        @AuraEnabled public String currentStageName;

        public JunctionRow(CDO_Promoted_Work_Item__c j) {
            id = j.Id;
            name = j.Name;
            status = j.Status__c;
            workItemId = j.Work_Item__c;
            workItemName = j.Work_Item__r?.Name;
            subject = j.Work_Item__r?.Subject__c;
            workItemStatus = j.Work_Item__r?.Status__c;
            currentStageName = j.Work_Item__r?.Current_Stage__r?.Name;
        }
    }

    public class CandidateView {
        @AuraEnabled public Id targetStageId;
        @AuraEnabled public String targetStageName;
        @AuraEnabled public Id previousStageId;
        @AuraEnabled public String previousStageName;
        @AuraEnabled public Boolean isEntry = false;
        @AuraEnabled public Boolean isProduction = false;
        @AuraEnabled public String message;
        @AuraEnabled public Boolean canApproveEntry = false;
        @AuraEnabled public List<Candidate> candidates = new List<Candidate>();
        @AuraEnabled public List<Candidate> ineligible = new List<Candidate>();
    }

    public class Candidate {
        @AuraEnabled public Id workItemId;
        @AuraEnabled public String name;
        @AuraEnabled public String subject;
        @AuraEnabled public String status;
        @AuraEnabled public String developerName;
        @AuraEnabled public String releaseName;
        @AuraEnabled public String currentStageName;
        @AuraEnabled public Boolean prApproved;
        @AuraEnabled public String prUrl;
        @AuraEnabled public Decimal coverage;
        @AuraEnabled public Decimal minimumCoverage;
        @AuraEnabled public Boolean eligible = true;
        @AuraEnabled public String reason;

        public Candidate(CDO_Work_Item__c wi) {
            workItemId = wi.Id;
            name = wi.Name;
            subject = wi.Subject__c;
            status = wi.Status__c;
            developerName = wi.Developer__r?.Name;
            releaseName = wi.Release__r?.Name;
            currentStageName = wi.Current_Stage__r?.Name;
            prApproved = wi.Pull_Requests_Approved__c == true;
            prUrl = wi.Pull_Request_URL__c;
            coverage = wi.Last_Coverage__c;
            minimumCoverage = wi.Minimum_Coverage__c;
        }
    }

    public class StageOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String label;
        @AuraEnabled public Decimal sortOrder;
        @AuraEnabled public String pipelineKey;
        @AuraEnabled public Boolean isEntry;
        @AuraEnabled public Boolean isProduction;

        public StageOption(CDO_Stage__c s, Boolean entry) {
            id = s.Id;
            name = s.Name;
            sortOrder = s.Order__c;
            pipelineKey = s.Pipeline_Key__c;
            isEntry = entry;
            isProduction = s.Is_Production__c == true;
            label = s.Name + (String.isBlank(s.Pipeline_Key__c) ? '' : ' (' + s.Pipeline_Key__c + ')') +
                (entry ? ' · entry' : '') + (isProduction ? ' · production' : '');
        }
    }

    public class PromotionPreview {
        @AuraEnabled public Id workItemId;
        @AuraEnabled public String workItemName;
        @AuraEnabled public String subject;
        @AuraEnabled public String status;
        @AuraEnabled public String currentStageName;
        @AuraEnabled public Id nextStageId;
        @AuraEnabled public String nextStageName;
        @AuraEnabled public Boolean isEntry = false;
        @AuraEnabled public Boolean isProduction = false;
        @AuraEnabled public Boolean canPromote = false;
        @AuraEnabled public String blockedReason;
        /** Promote & Deploy only: why the deploy would be held (coverage below the minimum). */
        @AuraEnabled public Boolean canDeploy = false;
        @AuraEnabled public String deployBlockedReason;
    }
}
