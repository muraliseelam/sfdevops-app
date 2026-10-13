/**
 * Server side of the work item command center (cdoWorkItemCommandCenter, cdoPromoteAction,
 * cdoPromoteDeployAction).
 *
 * getState returns everything the page shows plus availableActions, computed from the record's
 * state. performAction is the single mutating entry point. Apex forbids two @AuraEnabled methods
 * with the same name, so "promote" (a Draft promotion) and "promoteAndDeploy" (queued and
 * dispatched) are two action names that both wrap the one private promote method.
 */
public with sharing class CDOWorkItemCommandCenter {

    public static final String ACTION_COMMIT = 'commit';
    public static final String ACTION_OPEN_PR = 'openPr';
    public static final String ACTION_VALIDATE = 'validate';
    public static final String ACTION_PROMOTE = 'promote';
    public static final String ACTION_PROMOTE_AND_DEPLOY = 'promoteAndDeploy';
    /** Also accepted by performAction, outside availableActions. */
    public static final String ACTION_LIST_CHANGES = 'listChanges';
    public static final String ACTION_DISPATCH_PROMOTION = 'dispatchPromotion';

    public static final List<String> ACTIONS = new List<String>{
        ACTION_COMMIT, ACTION_OPEN_PR, ACTION_VALIDATE, ACTION_PROMOTE, ACTION_PROMOTE_AND_DEPLOY
    };
    private static final Integer RECENT = 10;

    public class State {
        @AuraEnabled public CDO_Work_Item__c workItem;
        @AuraEnabled public String featureBranch;
        /** The project's stages in order, current one marked. */
        @AuraEnabled public List<StageStep> path;
        @AuraEnabled public Id currentStageId;
        @AuraEnabled public String currentStageName;
        @AuraEnabled public Id nextStageId;
        @AuraEnabled public String nextStageName;
        /** Last 10, newest first. */
        @AuraEnabled public List<CDO_Commit__c> commits;
        @AuraEnabled public List<CDO_Component__c> components;
        /** Last 10, ORDER BY CreatedDate DESC, Id DESC. */
        @AuraEnabled public List<CDO_Deployment__c> deployments;
        /** Through the CDO_Promoted_Work_Item__c junction, newest first. */
        @AuraEnabled public List<PromotionInfo> promotions;
        @AuraEnabled public List<CDO_Approval__c> approvals;
        @AuraEnabled public Id openPromotionId;
        @AuraEnabled public String openPromotionName;
        @AuraEnabled public String openPromotionStatus;
        /** commit, openPr, validate, promote, promoteAndDeploy -> enabled. */
        @AuraEnabled public Map<String, Boolean> availableActions;
        /** Why an action is disabled, for each disabled action. */
        @AuraEnabled public Map<String, String> actionReasons;
        @AuraEnabled public Boolean dispatchEnabled;
        @AuraEnabled public String dispatchMessage;
        @AuraEnabled public String repoUrl;
    }

    public class StageStep {
        @AuraEnabled public Id stageId;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal order;
        @AuraEnabled public String pipelineKey;
        @AuraEnabled public String environmentName;
        @AuraEnabled public String healthStatus;
        @AuraEnabled public Boolean isEntry;
        @AuraEnabled public Boolean isProduction;
        @AuraEnabled public Boolean isCurrent;
        @AuraEnabled public Boolean isCompleted;
        @AuraEnabled public Boolean isNext;
    }

    public class PromotionInfo {
        @AuraEnabled public Id promotionId;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String itemStatus;
        @AuraEnabled public String direction;
        @AuraEnabled public String sourceStageName;
        @AuraEnabled public String targetStageName;
        @AuraEnabled public String runUrl;
        @AuraEnabled public String message;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Datetime dispatchedOn;
        @AuraEnabled public Datetime completedOn;
    }

    public class ActionResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public Id recordId;
        @AuraEnabled public String requestId;
    }

    @AuraEnabled(cacheable=true)
    public static State getState(Id workItemId) {
        try {
            return buildState(workItemId, true);
        } catch (Exception e) {
            throw auraError(e.getMessage());
        }
    }

    /**
     * actions: commit {components, message}, listChanges {sourceOrg}, openPr, validate,
     * promote / promoteAndDeploy {targetStageId, testLevel, specifiedTests, checkOnly, allowDestructive},
     * dispatchPromotion {promotionId}.
     */
    @AuraEnabled
    public static ActionResult performAction(Id workItemId, String action, String paramsJson) {
        String act = action == null ? '' : action.trim();
        try {
            Map<String, Object> params = parseParams(paramsJson);
            State st = buildState(workItemId, false);
            ActionResult result = new ActionResult();
            result.success = true;
            result.recordId = workItemId;
            switch on act {
                when 'commit' {
                    requireAvailable(st, ACTION_COMMIT);
                    Object components = params.get('components');
                    String componentsJson = components == null
                        ? text(params.get('componentsJson'))
                        : (components instanceof String ? (String) components : JSON.serialize(components));
                    CDO_WorkItemService.requestCommit(workItemId, componentsJson, text(params.get('message')));
                    result.message = 'Commit requested for ' + st.workItem.Name + '.';
                }
                when 'listChanges' {
                    result.requestId = CDO_WorkItemService.requestListChanges(workItemId, text(params.get('sourceOrg')));
                    result.message = 'Source changes requested for ' + st.workItem.Name + '.';
                }
                when 'openPr' {
                    requireAvailable(st, ACTION_OPEN_PR);
                    CDO_WorkItemService.openPullRequest(workItemId);
                    result.message = 'Pull request requested for ' + st.workItem.Name + '.';
                }
                when 'validate' {
                    requireAvailable(st, ACTION_VALIDATE);
                    CDO_WorkItemService.requestValidation(workItemId);
                    result.message = 'Validation requested for ' + st.workItem.Name + '.';
                }
                when 'promote', 'promoteAndDeploy' {
                    Boolean dispatchNow = act == ACTION_PROMOTE_AND_DEPLOY;
                    result.recordId = promote(st, params, dispatchNow);
                    result.message = dispatchNow
                        ? 'Promotion queued for ' + st.workItem.Name + '.'
                        : 'Draft promotion created for ' + st.workItem.Name + '.';
                }
                when 'dispatchPromotion' {
                    Object given = params.get('promotionId');
                    Id promotionId = given == null ? st.openPromotionId : Id.valueOf(String.valueOf(given));
                    if (promotionId == null) {
                        throw new CDOPromotionDispatcher.PromotionException(st.workItem.Name + ' has no open promotion to dispatch.');
                    }
                    CDOPromotionDispatcher.dispatchPromotion(promotionId);
                    result.recordId = promotionId;
                    result.message = 'Promotion queued.';
                }
                when else {
                    throw auraError('Unknown action "' + act + '".');
                }
            }
            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw auraError(e.getMessage());
        }
    }

    /** promote (Draft) and promoteAndDeploy (Queued, then dispatched) share this one method. */
    private static Id promote(State st, Map<String, Object> params, Boolean dispatchNow) {
        requireAvailable(st, dispatchNow ? ACTION_PROMOTE_AND_DEPLOY : ACTION_PROMOTE);
        Object given = params.get('targetStageId');
        Id targetStageId = given == null ? st.nextStageId : Id.valueOf(String.valueOf(given));
        Map<String, String> options = new Map<String, String>();
        for (String key : new List<String>{ 'testLevel', 'specifiedTests', 'checkOnly', 'allowDestructive', 'direction' }) {
            if (params.get(key) != null) {
                options.put(key, String.valueOf(params.get(key)));
            }
        }
        return CDOPromotionDispatcher.requestPromotion(new List<Id>{ st.workItem.Id }, targetStageId, options, dispatchNow);
    }

    private static State buildState(Id workItemId, Boolean forDisplay) {
        if (workItemId == null) {
            throw new CDO_WorkItemService.WorkItemException('A work item id is required.');
        }
        List<CDO_Work_Item__c> rows = [
            SELECT Id, Name, Subject__c, Status__c, Project__c, Project__r.Name, Current_Stage__c, Current_Stage__r.Name,
                Release__c, Release__r.Name, Developer__c, Developer__r.Name, Feature_Branch__c, Source_Org_Alias__c,
                Merge_State__c, Minimum_Coverage__c, Pull_Request_URL__c, Pull_Request_Number__c,
                Pull_Requests_Approved__c, Review_State__c, Story_Points__c, Specified_Tests__c, Test_Level_Override__c,
                Last_Coverage__c, Last_Tests_Passed__c, Last_Validation_Status__c, Last_Run_URL__c, Last_Commit_SHA__c,
                Blocked_Reason__c, Conflict_Paths__c, Source_Changes_JSON__c, Source_Changes_Status__c,
                Source_Changes_Received_On__c, Acceptance_Criteria__c, Description__c
            FROM CDO_Work_Item__c
            WHERE Id = :workItemId
        ];
        if (rows.isEmpty()) {
            throw new CDO_WorkItemService.WorkItemException('Work item ' + workItemId + ' was not found or is not visible to you.');
        }
        CDO_Work_Item__c wi = rows[0];
        List<CDO_Stage__c> stages = CDO_WorkItemService.orderedStages(wi.Project__c);
        CDO_Stage__c next = CDO_WorkItemService.nextStageFrom(stages, wi.Current_Stage__c);

        List<CDO_Commit__c> commits = [
            SELECT Id, Name, SHA__c, Branch__c, Message__c, Component_Count__c, Workflow_Run_URL__c, Committed_By__c,
                Committed_On__c, CreatedDate
            FROM CDO_Commit__c
            WHERE Work_Item__c = :workItemId
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT :RECENT
        ];
        List<CDO_Component__c> components = [
            SELECT Id, Name, Metadata_Type__c, Member_Name__c, Unique_ID__c, Action__c, Path__c, Last_Commit_Date__c,
                Last_Commit_SHA__c, Has_Conflict__c
            FROM CDO_Component__c
            WHERE Work_Item__c = :workItemId
            ORDER BY Metadata_Type__c ASC, Member_Name__c ASC
            LIMIT 1000
        ];
        List<CDO_Deployment__c> deployments = [
            SELECT Id, Name, Status__c, Event_Type__c, Check_Only__c, Workflow_Run_URL__c, Deploy_Id__c, Commit_SHA__c,
                Coverage_Percent__c, Tests_Passed__c, Failing_Methods__c, Message__c, Started_On__c, Completed_On__c,
                Component_Count__c, Test_Level__c, Stage__c, Stage__r.Name, Environment__c, Environment__r.Name,
                Promotion__c, Promotion__r.Name, CreatedDate
            FROM CDO_Deployment__c
            WHERE Work_Item__c = :workItemId
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT :RECENT
        ];
        List<CDO_Promoted_Work_Item__c> junction = [
            SELECT Id, Status__c, Promotion__c, Promotion__r.Name, Promotion__r.Status__c, Promotion__r.Direction__c,
                Promotion__r.Source_Stage__r.Name, Promotion__r.Target_Stage__r.Name, Promotion__r.Workflow_Run_URL__c,
                Promotion__r.Message__c, Promotion__r.CreatedDate, Promotion__r.Dispatched_On__c,
                Promotion__r.Completed_On__c
            FROM CDO_Promoted_Work_Item__c
            WHERE Work_Item__c = :workItemId
            ORDER BY Promotion__r.CreatedDate DESC, Promotion__c DESC
            LIMIT 50
        ];
        List<CDO_Approval__c> approvals = [
            SELECT Id, Name, Approver__c, Method__c, Decision__c, Decided_On__c, Comments__c, Source_URL__c,
                Stage__c, Stage__r.Name, Promotion__c, Promotion__r.Name, CreatedDate
            FROM CDO_Approval__c
            WHERE Work_Item__c = :workItemId
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 20
        ];

        State st = new State();
        st.featureBranch = CDO_WorkItemService.featureBranch(wi);
        st.currentStageId = wi.Current_Stage__c;
        st.currentStageName = wi.Current_Stage__c == null ? null : wi.Current_Stage__r.Name;
        st.nextStageId = next == null ? null : next.Id;
        st.nextStageName = next == null ? null : next.Name;
        st.dispatchMessage = GitHubService.configurationError();
        st.dispatchEnabled = st.dispatchMessage == null;
        st.repoUrl = GitHubService.repoUrl();
        st.path = buildPath(stages, wi.Current_Stage__c, next);
        st.promotions = new List<PromotionInfo>();
        for (CDO_Promoted_Work_Item__c row : junction) {
            PromotionInfo info = new PromotionInfo();
            info.promotionId = row.Promotion__c;
            info.name = row.Promotion__r.Name;
            info.status = row.Promotion__r.Status__c;
            info.itemStatus = row.Status__c;
            info.direction = row.Promotion__r.Direction__c;
            info.sourceStageName = row.Promotion__r.Source_Stage__r == null ? null : row.Promotion__r.Source_Stage__r.Name;
            info.targetStageName = row.Promotion__r.Target_Stage__r == null ? null : row.Promotion__r.Target_Stage__r.Name;
            info.runUrl = row.Promotion__r.Workflow_Run_URL__c;
            info.message = row.Promotion__r.Message__c;
            info.createdDate = row.Promotion__r.CreatedDate;
            info.dispatchedOn = row.Promotion__r.Dispatched_On__c;
            info.completedOn = row.Promotion__r.Completed_On__c;
            st.promotions.add(info);
            if (st.openPromotionId == null && CDOPromotionDispatcher.OPEN_STATUSES.contains(info.status)) {
                st.openPromotionId = info.promotionId;
                st.openPromotionName = info.name;
                st.openPromotionStatus = info.status;
            }
        }
        Boolean hasCommits = !commits.isEmpty() || String.isNotBlank(wi.Last_Commit_SHA__c);
        computeActions(st, wi, next, hasCommits);

        if (forDisplay) {
            // Show only what the viewer may read; the computation above used the full records.
            st.workItem = (CDO_Work_Item__c) Security.stripInaccessible(AccessType.READABLE, rows).getRecords()[0];
            st.commits = (List<CDO_Commit__c>) Security.stripInaccessible(AccessType.READABLE, commits).getRecords();
            st.components = (List<CDO_Component__c>) Security.stripInaccessible(AccessType.READABLE, components).getRecords();
            st.deployments = (List<CDO_Deployment__c>) Security.stripInaccessible(AccessType.READABLE, deployments).getRecords();
            st.approvals = (List<CDO_Approval__c>) Security.stripInaccessible(AccessType.READABLE, approvals).getRecords();
        } else {
            st.workItem = wi;
            st.commits = commits;
            st.components = components;
            st.deployments = deployments;
            st.approvals = approvals;
        }
        return st;
    }

    private static List<StageStep> buildPath(List<CDO_Stage__c> stages, Id currentStageId, CDO_Stage__c next) {
        List<StageStep> path = new List<StageStep>();
        Integer currentIndex = -1;
        for (Integer i = 0; i < stages.size(); i++) {
            if (stages[i].Id == currentStageId) {
                currentIndex = i;
            }
        }
        for (Integer i = 0; i < stages.size(); i++) {
            CDO_Stage__c s = stages[i];
            StageStep step = new StageStep();
            step.stageId = s.Id;
            step.name = s.Name;
            step.order = s.Order__c;
            step.pipelineKey = s.Pipeline_Key__c;
            step.environmentName = s.Environment__c == null ? null : s.Environment__r.Name;
            step.healthStatus = s.Environment__c == null ? null : s.Environment__r.Health_Status__c;
            step.isEntry = s.Is_Entry__c == true;
            step.isProduction = s.Is_Production__c == true;
            step.isCurrent = i == currentIndex;
            step.isCompleted = currentIndex >= 0 && i < currentIndex;
            step.isNext = next != null && s.Id == next.Id;
            path.add(step);
        }
        return path;
    }

    /** Each action enabled or not, and why not. The server enforces the same rules in performAction. */
    private static void computeActions(State st, CDO_Work_Item__c wi, CDO_Stage__c next, Boolean hasCommits) {
        Map<String, String> reasons = new Map<String, String>();
        Boolean closed = CDO_WorkItemService.CLOSED_STATUSES.contains(wi.Status__c);
        String closedReason = wi.Name + ' is ' + wi.Status__c + '.';
        String dispatchReason = st.dispatchMessage;

        if (closed) {
            reasons.put(ACTION_COMMIT, closedReason);
        } else if (dispatchReason != null) {
            reasons.put(ACTION_COMMIT, dispatchReason);
        }

        if (closed) {
            reasons.put(ACTION_OPEN_PR, closedReason);
        } else if (wi.Pull_Request_Number__c != null || String.isNotBlank(wi.Pull_Request_URL__c)) {
            reasons.put(ACTION_OPEN_PR, 'A pull request is already open.');
        } else if (!hasCommits) {
            reasons.put(ACTION_OPEN_PR, 'Commit changes before opening a pull request.');
        } else if (dispatchReason != null) {
            reasons.put(ACTION_OPEN_PR, dispatchReason);
        }

        if (closed) {
            reasons.put(ACTION_VALIDATE, closedReason);
        } else if (wi.Pull_Request_Number__c == null) {
            reasons.put(ACTION_VALIDATE, 'Open a pull request before validating.');
        } else if (wi.Last_Validation_Status__c == 'Running') {
            reasons.put(ACTION_VALIDATE, 'A validation is already running.');
        } else if (dispatchReason != null) {
            reasons.put(ACTION_VALIDATE, dispatchReason);
        }

        String promoteReason;
        if (closed) {
            promoteReason = closedReason;
        } else if (next == null) {
            promoteReason = wi.Project__c == null ? wi.Name + ' has no project.' : wi.Name + ' is at the last stage.';
        } else if (next.Is_Production__c == true) {
            promoteReason = 'Production ships through a release, not a promotion.';
        } else if (st.openPromotionId != null) {
            promoteReason = st.openPromotionName + ' is already ' + st.openPromotionStatus + '.';
        } else if (!hasCommits) {
            promoteReason = 'Commit changes before promoting.';
        } else if (next.Is_Entry__c == true && wi.Pull_Requests_Approved__c != true) {
            promoteReason = 'The pull request must be approved before the entry stage.';
        } else if (wi.Minimum_Coverage__c != null && wi.Last_Coverage__c != null && wi.Last_Coverage__c < wi.Minimum_Coverage__c) {
            promoteReason = 'Coverage ' + wi.Last_Coverage__c + '% is below the minimum ' + wi.Minimum_Coverage__c + '%.';
        }
        if (promoteReason != null) {
            reasons.put(ACTION_PROMOTE, promoteReason);
            reasons.put(ACTION_PROMOTE_AND_DEPLOY, promoteReason);
        } else if (dispatchReason != null) {
            reasons.put(ACTION_PROMOTE_AND_DEPLOY, dispatchReason);
        }

        st.availableActions = new Map<String, Boolean>();
        for (String a : ACTIONS) {
            st.availableActions.put(a, !reasons.containsKey(a));
        }
        st.actionReasons = reasons;
    }

    private static void requireAvailable(State st, String action) {
        if (st.availableActions.get(action) != true) {
            throw auraError(st.actionReasons.containsKey(action) ? st.actionReasons.get(action) : action + ' is not available.');
        }
    }

    private static Map<String, Object> parseParams(String paramsJson) {
        if (String.isBlank(paramsJson)) {
            return new Map<String, Object>();
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(paramsJson);
        } catch (Exception e) {
            throw auraError('paramsJson is not valid JSON.');
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw auraError('paramsJson must be a JSON object.');
        }
        return (Map<String, Object>) parsed;
    }

    private static String text(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
