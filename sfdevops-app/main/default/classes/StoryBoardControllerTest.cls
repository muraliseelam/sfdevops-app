/**
 * StoryBoardController: stage columns with cards, the release filter, the refusal to move a card
 * by hand, and requestPromotion delegating to the promotion logic.
 */
@IsTest
private class StoryBoardControllerTest {

    private class GitHubMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(req.getEndpoint().endsWith('/dispatches') ? 204 : 200);
            res.setBody(req.getEndpoint().endsWith('/dispatches') ? '' : '{"full_name":"acme/sf-repo"}');
            return res;
        }
    }

    @TestSetup
    static void setup() {
        insert new CDO_Settings__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            GitHub_Owner__c = 'acme',
            GitHub_Repo__c = 'sf-repo',
            Workflow_Ref__c = 'main',
            Named_Credential__c = 'GitHub_API',
            Dispatch_Enabled__c = true,
            Default_Project_Key__c = 'board'
        );
        CDO_Project__c project = new CDO_Project__c(Name = 'Board', Key__c = 'board', Active__c = true);
        insert project;
        CDO_Environment__c intEnv = new CDO_Environment__c(Name = 'Int', Key__c = 'board:int', Project__c = project.Id,
            Pipeline_Key__c = 'int', Type__c = 'Pipeline', Health_Status__c = 'Healthy');
        CDO_Environment__c qaEnv = new CDO_Environment__c(Name = 'QA', Key__c = 'board:qa', Project__c = project.Id,
            Pipeline_Key__c = 'qa', Type__c = 'Pipeline');
        CDO_Environment__c prodEnv = new CDO_Environment__c(Name = 'Prod', Key__c = 'board:prod', Project__c = project.Id,
            Pipeline_Key__c = 'prod', Type__c = 'Production');
        insert new List<CDO_Environment__c>{ intEnv, qaEnv, prodEnv };
        CDO_Stage__c sInt = new CDO_Stage__c(Name = 'INT', Key__c = 'board:int', Project__c = project.Id, Environment__c = intEnv.Id,
            Order__c = 1, Is_Entry__c = true, Pipeline_Key__c = 'int', Branch__c = 'int');
        CDO_Stage__c sQa = new CDO_Stage__c(Name = 'QA', Key__c = 'board:qa', Project__c = project.Id, Environment__c = qaEnv.Id,
            Order__c = 2, Pipeline_Key__c = 'qa', Branch__c = 'qa');
        CDO_Stage__c sProd = new CDO_Stage__c(Name = 'PROD', Key__c = 'board:prod', Project__c = project.Id, Environment__c = prodEnv.Id,
            Order__c = 3, Pipeline_Key__c = 'prod', Branch__c = 'main', Is_Production__c = true);
        insert new List<CDO_Stage__c>{ sInt, sQa, sProd };
        CDO_Release__c rel = new CDO_Release__c(Name = 'R1', Project__c = project.Id, Status__c = 'Planned');
        insert rel;
        insert new List<CDO_Work_Item__c>{
            new CDO_Work_Item__c(Subject__c = 'Backlog item', Status__c = 'New', Project__c = project.Id, Story_Points__c = 3),
            new CDO_Work_Item__c(Subject__c = 'In INT', Status__c = 'Deployed', Project__c = project.Id, Current_Stage__c = sInt.Id,
                Release__c = rel.Id, Story_Points__c = 5, Last_Commit_SHA__c = 'abc1234'),
            new CDO_Work_Item__c(Subject__c = 'Blocked in INT', Status__c = 'Blocked', Project__c = project.Id,
                Current_Stage__c = sInt.Id, Blocked_Reason__c = 'Deploy failed'),
            new CDO_Work_Item__c(Subject__c = 'Cancelled', Status__c = 'Cancelled', Project__c = project.Id)
        };
    }

    private static CDO_Work_Item__c item(String subject) {
        return [SELECT Id, Name, Current_Stage__c FROM CDO_Work_Item__c WHERE Subject__c = :subject LIMIT 1];
    }

    @IsTest
    static void boardHasBacklogThenStagesInOrder() {
        StoryBoardController.Board board = StoryBoardController.getBoard(null, null);

        Assert.areEqual('Board', board.projectName);
        Assert.areEqual(4, board.columns.size(), 'Backlog plus three stages');
        Assert.isTrue(board.columns[0].isBacklog);
        Assert.areEqual('INT', board.columns[1].label);
        Assert.areEqual('QA', board.columns[2].label);
        Assert.areEqual('PROD', board.columns[3].label);
        Assert.isTrue(board.columns[3].isProduction);
        Assert.areEqual('Healthy', board.columns[1].healthStatus);
        Assert.areEqual(1, board.columns[0].count, 'Cancelled work items are not shown');
        Assert.areEqual(3, board.columns[0].points);
        Assert.areEqual(2, board.columns[1].count);
        Assert.areEqual(5, board.columns[1].points);
        Boolean sawBlocked = false;
        for (StoryBoardController.Card c : board.columns[1].cards) {
            if (c.blocked) {
                sawBlocked = true;
                Assert.areEqual('Deploy failed', c.blockedReason);
            }
        }
        Assert.isTrue(sawBlocked);
        Assert.isNull(board.emptyMessage);
    }

    @IsTest
    static void boardFiltersByRelease() {
        CDO_Release__c rel = [SELECT Id FROM CDO_Release__c LIMIT 1];
        StoryBoardController.Board board = StoryBoardController.getBoard(null, rel.Id);

        Integer total = 0;
        for (StoryBoardController.Column c : board.columns) {
            total += c.count;
        }
        Assert.areEqual(1, total);
        Assert.areEqual('R1', board.columns[1].cards[0].releaseName);
        Assert.areEqual(rel.Id, board.releaseId);
    }

    @IsTest
    static void boardWithoutStagesSaysHowToSeed() {
        CDO_Project__c empty = new CDO_Project__c(Name = 'Empty', Key__c = 'empty', Active__c = true);
        insert empty;
        StoryBoardController.Board board = StoryBoardController.getBoard(empty.Id, null);

        Assert.areEqual(1, board.columns.size());
        Assert.isTrue(board.emptyMessage.contains('seed-pipeline.py'));
    }

    @IsTest
    static void boardWithoutProjectIsEmpty() {
        delete [SELECT Id FROM CDO_Work_Item__c];
        delete [SELECT Id FROM CDO_Release__c];
        delete [SELECT Id FROM CDO_Project__c];
        StoryBoardController.Board board = StoryBoardController.getBoard(null, null);

        Assert.isNull(board.projectId);
        Assert.isTrue(board.columns.isEmpty());
        Assert.isTrue(board.emptyMessage.contains('seed-pipeline.py'));
    }

    @IsTest
    static void movingACardByHandIsRefused() {
        CDO_Work_Item__c wi = item('Backlog item');
        CDO_Stage__c qa = [SELECT Id FROM CDO_Stage__c WHERE Key__c = 'board:qa'];
        try {
            StoryBoardController.moveToStage(wi.Id, qa.Id);
            Assert.fail('moveToStage must refuse');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('promotion'), e.getMessage());
        }
        Assert.isNull(item('Backlog item').Current_Stage__c, 'The stage must not change');
    }

    @IsTest
    static void requestPromotionQueuesThePromotion() {
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        CDO_Work_Item__c wi = item('In INT');

        Test.startTest();
        PromotionController.PromotionResult result = StoryBoardController.requestPromotion(wi.Id);
        Test.stopTest();

        Assert.isNotNull(result.promotionId);
        Assert.areEqual('QA', result.targetStageName);
        Assert.isTrue(result.dispatched);
        CDO_Promotion__c p = [
            SELECT Status__c, Target_Stage__r.Name, (SELECT Work_Item__c FROM Promoted_Work_Items__r)
            FROM CDO_Promotion__c WHERE Id = :result.promotionId
        ];
        Assert.areEqual(1, p.Promoted_Work_Items__r.size(), 'The junction row is written');
        Assert.areEqual(wi.Id, p.Promoted_Work_Items__r[0].Work_Item__c);
        Assert.isTrue(p.Status__c == 'Queued' || p.Status__c == 'Dispatched', p.Status__c);
    }

    @IsTest
    static void requestPromotionAtProductionIsRefused() {
        CDO_Work_Item__c wi = item('In INT');
        CDO_Stage__c prod = [SELECT Id FROM CDO_Stage__c WHERE Key__c = 'board:prod'];
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = prod.Id);
        try {
            StoryBoardController.requestPromotion(wi.Id);
            Assert.fail('Promoting past production must be refused');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('production'), e.getMessage());
        }
    }
}
