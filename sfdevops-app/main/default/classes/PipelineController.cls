/**
 * Read model for cdoPipeline: a project's stages left to right, each with its environment
 * health, work-item counts, in-flight promotions and latest deployment.
 *
 * Also the shared place that resolves "the current project" and orders a project's stages,
 * so every controller agrees on which stage comes before which.
 */
public with sharing class PipelineController {

    public static final Set<String> IN_FLIGHT_PROMOTION = new Set<String>{ 'Queued', 'Dispatched', 'Deploying' };
    public static final Set<String> CLOSED_WORK_ITEM = new Set<String>{ 'Done', 'Cancelled' };
    private static final Integer WORK_ITEMS_PER_STAGE = 8;

    @AuraEnabled(cacheable=true)
    public static List<CDO_Project__c> getProjects() {
        return [
            SELECT Id, Name, Key__c, Repository__c, Baseline_Branch__c, Coverage_Threshold__c, Active__c
            FROM CDO_Project__c
            WHERE Active__c = true
            ORDER BY Name
            LIMIT 200
        ];
    }

    @AuraEnabled(cacheable=true)
    public static PipelineView getPipeline(Id projectId) {
        PipelineView view = new PipelineView();
        CDO_Project__c project = resolveProject(projectId);
        if (project == null) {
            view.emptyMessage = 'No projects yet. Run seed-pipeline.py to load the project, environments and stages from pipeline.config.yml.';
            return view;
        }
        view.projectId = project.Id;
        view.projectName = project.Name;
        view.repository = project.Repository__c;
        view.baselineBranch = project.Baseline_Branch__c;
        view.repoUrl = safeRepoUrl();

        List<CDO_Stage__c> stages = orderedStages(project.Id);
        if (stages.isEmpty()) {
            view.emptyMessage = 'No stages configured yet — run seed-pipeline.py.';
            return view;
        }
        CDO_Stage__c entry = entryStage(stages);
        Map<Id, StageCard> cards = new Map<Id, StageCard>();
        Integer position = 0;
        for (CDO_Stage__c s : stages) {
            StageCard card = new StageCard(s);
            card.position = ++position;
            card.isEntry = entry != null && s.Id == entry.Id;
            card.isLast = position == stages.size();
            cards.put(s.Id, card);
            view.stages.add(card);
        }
        Set<Id> stageIds = cards.keySet();

        for (AggregateResult ar : [
            SELECT Current_Stage__c stageId, Status__c status, COUNT(Id) total
            FROM CDO_Work_Item__c
            WHERE Current_Stage__c IN :stageIds AND Status__c != 'Cancelled'
            GROUP BY Current_Stage__c, Status__c
        ]) {
            StageCard card = cards.get((Id) ar.get('stageId'));
            Integer total = (Integer) ar.get('total');
            card.workItemCount += total;
            if ((String) ar.get('status') == 'Blocked') {
                card.blockedCount += total;
            }
        }

        for (CDO_Work_Item__c wi : [
            SELECT Id, Name, Subject__c, Status__c, Current_Stage__c, Merge_State__c, Developer__r.Name
            FROM CDO_Work_Item__c
            WHERE Current_Stage__c IN :stageIds AND Status__c != 'Cancelled'
            ORDER BY LastModifiedDate DESC, Id DESC
            LIMIT 1000
        ]) {
            StageCard card = cards.get(wi.Current_Stage__c);
            if (card.workItems.size() < WORK_ITEMS_PER_STAGE) {
                card.workItems.add(new WorkItemChip(wi));
            }
        }

        for (CDO_Promotion__c p : [
            SELECT Id, Name, Status__c, Direction__c, Target_Stage__c, Source_Stage__r.Name, Target_Stage__r.Name,
                   Workflow_Run_URL__c, Dispatched_On__c, CreatedDate,
                   (SELECT Work_Item__r.Name FROM Promoted_Work_Items__r ORDER BY Work_Item__r.Name)
            FROM CDO_Promotion__c
            WHERE Target_Stage__c IN :stageIds AND Status__c IN :IN_FLIGHT_PROMOTION
            ORDER BY CreatedDate ASC, Id ASC
            LIMIT 500
        ]) {
            StageCard card = cards.get(p.Target_Stage__c);
            card.inFlight.add(new PromotionSummary(p));
            if (p.Status__c == 'Queued') {
                card.queuedCount++;
            }
        }

        // Latest deployment per stage: one child row per parent, ordered with an Id tie-break.
        for (CDO_Stage__c s : [
            SELECT Id,
                   (SELECT Id, Name, Status__c, Event_Type__c, Check_Only__c, Workflow_Run_URL__c,
                           Coverage_Percent__c, Tests_Passed__c, Completed_On__c, CreatedDate, Message__c,
                           Work_Item__c, Work_Item__r.Name, Promotion__c, Promotion__r.Name, Release__r.Name
                    FROM Deployments__r
                    ORDER BY CreatedDate DESC, Id DESC
                    LIMIT 1)
            FROM CDO_Stage__c
            WHERE Id IN :stageIds
        ]) {
            if (!s.Deployments__r.isEmpty()) {
                cards.get(s.Id).latestDeployment = new DeploymentSummary(s.Deployments__r[0]);
            }
        }

        for (AggregateResult ar : [
            SELECT Status__c status, COUNT(Id) total
            FROM CDO_Work_Item__c
            WHERE Project__c = :project.Id AND Current_Stage__c = null AND Status__c NOT IN :CLOSED_WORK_ITEM
            GROUP BY Status__c
        ]) {
            Integer total = (Integer) ar.get('total');
            view.backlogCount += total;
            if ((String) ar.get('status') == 'Approved') {
                view.approvedBacklogCount += total;
            }
        }
        view.hasStages = true;
        return view;
    }

    // ----------------------------------------------------------------------------------------
    // Shared helpers (used by the other controllers)
    // ----------------------------------------------------------------------------------------

    /**
     * The given project, else the project named by CDO_Settings__c.Default_Project_Key__c, else
     * the first active project by name. Null when there is no project at all.
     */
    public static CDO_Project__c resolveProject(Id projectId) {
        List<CDO_Project__c> rows;
        if (projectId != null) {
            rows = [SELECT Id, Name, Key__c, Repository__c, Baseline_Branch__c FROM CDO_Project__c WHERE Id = :projectId];
            return rows.isEmpty() ? null : rows[0];
        }
        CDO_Settings__c settings = CDO_Settings__c.getInstance();
        if (settings != null && String.isNotBlank(settings.Default_Project_Key__c)) {
            String key = settings.Default_Project_Key__c;
            rows = [SELECT Id, Name, Key__c, Repository__c, Baseline_Branch__c FROM CDO_Project__c WHERE Key__c = :key];
            if (!rows.isEmpty()) {
                return rows[0];
            }
        }
        rows = [
            SELECT Id, Name, Key__c, Repository__c, Baseline_Branch__c
            FROM CDO_Project__c
            WHERE Active__c = true
            ORDER BY Name
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /** The project's stages in promotion order (Order__c, then Id, as CDO_WorkItemService orders them). */
    public static List<CDO_Stage__c> orderedStages(Id projectId) {
        return [
            SELECT Id, Name, Key__c, Order__c, Pipeline_Key__c, Branch__c, Gate_Type__c, Coverage_Floor__c,
                   Is_Entry__c, Is_Production__c, Test_Level__c, Project__c,
                   Environment__c, Environment__r.Name, Environment__r.Health_Status__c,
                   Environment__r.Last_Deployed_On__c, Environment__r.Instance_URL__c, Environment__r.Type__c,
                   Environment__r.Pipeline_Key__c
            FROM CDO_Stage__c
            WHERE Project__c = :projectId
            ORDER BY Order__c ASC NULLS LAST, Id ASC
        ];
    }

    /** The stage flagged Is_Entry__c; when none is flagged, the first stage in order. */
    public static CDO_Stage__c entryStage(List<CDO_Stage__c> ordered) {
        if (ordered == null || ordered.isEmpty()) {
            return null;
        }
        for (CDO_Stage__c s : ordered) {
            if (s.Is_Entry__c == true) {
                return s;
            }
        }
        return ordered[0];
    }

    /** The stage immediately before the given one in its project's order; null for the first. */
    public static CDO_Stage__c previousStage(Id stageId, List<CDO_Stage__c> ordered) {
        for (Integer i = 0; i < ordered.size(); i++) {
            if (ordered[i].Id == stageId) {
                return i == 0 ? null : ordered[i - 1];
            }
        }
        return null;
    }

    private static String safeRepoUrl() {
        try {
            return GitHubService.repoUrl();
        } catch (Exception e) {
            return null;
        }
    }

    // ----------------------------------------------------------------------------------------
    // View models
    // ----------------------------------------------------------------------------------------

    public class PipelineView {
        @AuraEnabled public Id projectId;
        @AuraEnabled public String projectName;
        @AuraEnabled public String repository;
        @AuraEnabled public String baselineBranch;
        @AuraEnabled public String repoUrl;
        @AuraEnabled public Boolean hasStages = false;
        @AuraEnabled public String emptyMessage;
        @AuraEnabled public Integer backlogCount = 0;
        @AuraEnabled public Integer approvedBacklogCount = 0;
        @AuraEnabled public List<StageCard> stages = new List<StageCard>();
    }

    public class StageCard {
        @AuraEnabled public Id stageId;
        @AuraEnabled public String name;
        @AuraEnabled public Integer position;
        @AuraEnabled public Decimal sortOrder;
        @AuraEnabled public String pipelineKey;
        @AuraEnabled public String branch;
        @AuraEnabled public String gateType;
        @AuraEnabled public Decimal coverageFloor;
        @AuraEnabled public Boolean isEntry = false;
        @AuraEnabled public Boolean isProduction = false;
        @AuraEnabled public Boolean isLast = false;
        @AuraEnabled public Id environmentId;
        @AuraEnabled public String environmentName;
        @AuraEnabled public String healthStatus;
        @AuraEnabled public Datetime lastDeployedOn;
        @AuraEnabled public String instanceUrl;
        @AuraEnabled public Integer workItemCount = 0;
        @AuraEnabled public Integer blockedCount = 0;
        @AuraEnabled public Integer queuedCount = 0;
        @AuraEnabled public List<WorkItemChip> workItems = new List<WorkItemChip>();
        @AuraEnabled public List<PromotionSummary> inFlight = new List<PromotionSummary>();
        @AuraEnabled public DeploymentSummary latestDeployment;

        public StageCard(CDO_Stage__c s) {
            stageId = s.Id;
            name = s.Name;
            sortOrder = s.Order__c;
            pipelineKey = s.Pipeline_Key__c;
            branch = s.Branch__c;
            gateType = s.Gate_Type__c;
            coverageFloor = s.Coverage_Floor__c;
            isProduction = s.Is_Production__c == true;
            environmentId = s.Environment__c;
            environmentName = s.Environment__r?.Name;
            healthStatus = s.Environment__r?.Health_Status__c;
            lastDeployedOn = s.Environment__r?.Last_Deployed_On__c;
            instanceUrl = s.Environment__r?.Instance_URL__c;
        }
    }

    public class WorkItemChip {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String subject;
        @AuraEnabled public String status;
        @AuraEnabled public String mergeState;
        @AuraEnabled public String developerName;

        public WorkItemChip(CDO_Work_Item__c wi) {
            id = wi.Id;
            name = wi.Name;
            subject = wi.Subject__c;
            status = wi.Status__c;
            mergeState = wi.Merge_State__c;
            developerName = wi.Developer__r?.Name;
        }
    }

    public class PromotionSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String direction;
        @AuraEnabled public String sourceStageName;
        @AuraEnabled public String targetStageName;
        @AuraEnabled public String runUrl;
        @AuraEnabled public Datetime dispatchedOn;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Integer workItemCount;
        @AuraEnabled public String workItemKeys;

        public PromotionSummary(CDO_Promotion__c p) {
            id = p.Id;
            name = p.Name;
            status = p.Status__c;
            direction = p.Direction__c;
            sourceStageName = p.Source_Stage__r?.Name;
            targetStageName = p.Target_Stage__r?.Name;
            runUrl = p.Workflow_Run_URL__c;
            dispatchedOn = p.Dispatched_On__c;
            createdDate = p.CreatedDate;
            List<String> keys = new List<String>();
            for (CDO_Promoted_Work_Item__c j : p.Promoted_Work_Items__r) {
                if (j.Work_Item__r != null) {
                    keys.add(j.Work_Item__r.Name);
                }
            }
            workItemCount = keys.size();
            workItemKeys = String.join(keys, ', ');
        }
    }

    public class DeploymentSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String eventType;
        @AuraEnabled public Boolean checkOnly;
        @AuraEnabled public String runUrl;
        @AuraEnabled public Decimal coveragePercent;
        @AuraEnabled public Boolean testsPassed;
        @AuraEnabled public Datetime completedOn;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public String message;
        @AuraEnabled public Id workItemId;
        @AuraEnabled public String workItemName;
        @AuraEnabled public Id promotionId;
        @AuraEnabled public String promotionName;
        @AuraEnabled public String releaseName;

        public DeploymentSummary(CDO_Deployment__c d) {
            id = d.Id;
            name = d.Name;
            status = d.Status__c;
            eventType = d.Event_Type__c;
            checkOnly = d.Check_Only__c;
            runUrl = d.Workflow_Run_URL__c;
            coveragePercent = d.Coverage_Percent__c;
            testsPassed = d.Tests_Passed__c;
            completedOn = d.Completed_On__c;
            createdDate = d.CreatedDate;
            message = d.Message__c;
            workItemId = d.Work_Item__c;
            workItemName = d.Work_Item__r?.Name;
            promotionId = d.Promotion__c;
            promotionName = d.Promotion__r?.Name;
            releaseName = d.Release__r?.Name;
        }
    }
}
