/**
 * Story board: a project's work items as cards in stage columns (Backlog first, then each stage
 * in promotion order), optionally narrowed to one release.
 *
 * Cards are never dragged between stages. A work item's stage changes only when a promotion to
 * that stage deploys, so moveToStage refuses and points at requestPromotion instead.
 */
public with sharing class StoryBoardController {

    public static final String BACKLOG_KEY = 'backlog';
    private static final Integer MAX_CARDS = 2000;

    @AuraEnabled(cacheable=true)
    public static Board getBoard(Id projectId, Id releaseId) {
        Board board = new Board();
        CDO_Project__c project = PipelineController.resolveProject(projectId);
        if (project == null) {
            board.emptyMessage = 'No projects yet. Run seed-pipeline.py to load the pipeline.';
            return board;
        }
        board.projectId = project.Id;
        board.projectName = project.Name;
        board.releaseId = releaseId;

        Column backlog = new Column(BACKLOG_KEY, 'Backlog', null);
        backlog.isBacklog = true;
        board.columns.add(backlog);
        Map<Id, Column> byStage = new Map<Id, Column>();
        List<CDO_Stage__c> stages = PipelineController.orderedStages(project.Id);
        for (CDO_Stage__c s : stages) {
            Column c = new Column(s.Id, s.Name, s.Id);
            c.pipelineKey = s.Pipeline_Key__c;
            c.isProduction = s.Is_Production__c == true;
            c.healthStatus = s.Environment__r?.Health_Status__c;
            byStage.put(s.Id, c);
            board.columns.add(c);
        }
        if (stages.isEmpty()) {
            board.emptyMessage = 'No stages configured yet — run seed-pipeline.py.';
        }

        Id pid = project.Id;
        String soql =
            'SELECT Id, Name, Subject__c, Status__c, Current_Stage__c, Story_Points__c, Merge_State__c, ' +
            'Pull_Request_URL__c, Pull_Requests_Approved__c, Last_Coverage__c, Last_Validation_Status__c, ' +
            'Blocked_Reason__c, Developer__r.Name, Release__c, Release__r.Name ' +
            'FROM CDO_Work_Item__c WHERE Project__c = :pid AND Status__c != \'Cancelled\'' +
            (releaseId == null ? '' : ' AND Release__c = :releaseId') +
            ' ORDER BY LastModifiedDate DESC, Id DESC LIMIT :maxCards';
        Map<String, Object> binds = new Map<String, Object>{ 'pid' => pid, 'releaseId' => releaseId, 'maxCards' => MAX_CARDS };
        for (CDO_Work_Item__c wi : (List<CDO_Work_Item__c>) Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE)) {
            Column target = wi.Current_Stage__c == null ? backlog : byStage.get(wi.Current_Stage__c);
            if (target == null) {
                // Stage from another project: show it in the backlog rather than lose the card.
                target = backlog;
            }
            target.cards.add(new Card(wi));
            target.count++;
            if (wi.Story_Points__c != null) {
                target.points += wi.Story_Points__c;
            }
        }
        return board;
    }

    /** Refused by design: the stage changes only through a promotion. */
    @AuraEnabled
    public static void moveToStage(Id workItemId, Id stageId) {
        throw fail('Work items cannot be moved between stages by hand. A work item reaches a stage when a promotion ' +
            'to that stage deploys. Use Promote (requestPromotion) instead.');
    }

    /** Promote the work item to its next stage and queue the deploy, as the Promote & Deploy action does. */
    @AuraEnabled
    public static PromotionController.PromotionResult requestPromotion(Id workItemId) {
        return PromotionController.promoteWorkItem(workItemId);
    }

    private static AuraHandledException fail(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    // ----------------------------------------------------------------------------------------

    public class Board {
        @AuraEnabled public Id projectId;
        @AuraEnabled public String projectName;
        @AuraEnabled public Id releaseId;
        @AuraEnabled public String emptyMessage;
        @AuraEnabled public List<Column> columns = new List<Column>();
    }

    public class Column {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public Id stageId;
        @AuraEnabled public String pipelineKey;
        @AuraEnabled public String healthStatus;
        @AuraEnabled public Boolean isBacklog = false;
        @AuraEnabled public Boolean isProduction = false;
        @AuraEnabled public Integer count = 0;
        @AuraEnabled public Decimal points = 0;
        @AuraEnabled public List<Card> cards = new List<Card>();

        public Column(String key, String label, Id stageId) {
            this.key = key;
            this.label = label;
            this.stageId = stageId;
        }
    }

    public class Card {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String subject;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal storyPoints;
        @AuraEnabled public String mergeState;
        @AuraEnabled public String developerName;
        @AuraEnabled public Id releaseId;
        @AuraEnabled public String releaseName;
        @AuraEnabled public String prUrl;
        @AuraEnabled public Boolean prApproved;
        @AuraEnabled public Decimal coverage;
        @AuraEnabled public String validationStatus;
        @AuraEnabled public Boolean blocked;
        @AuraEnabled public String blockedReason;

        public Card(CDO_Work_Item__c wi) {
            id = wi.Id;
            name = wi.Name;
            subject = wi.Subject__c;
            status = wi.Status__c;
            storyPoints = wi.Story_Points__c;
            mergeState = wi.Merge_State__c;
            developerName = wi.Developer__r?.Name;
            releaseId = wi.Release__c;
            releaseName = wi.Release__r?.Name;
            prUrl = wi.Pull_Request_URL__c;
            prApproved = wi.Pull_Requests_Approved__c == true;
            coverage = wi.Last_Coverage__c;
            validationStatus = wi.Last_Validation_Status__c;
            blocked = wi.Status__c == 'Blocked';
            blockedReason = wi.Blocked_Reason__c;
        }
    }
}
