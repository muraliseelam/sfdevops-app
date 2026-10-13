/**
 * Tests for the LWC controllers: Pipeline, Promotion, WorkItem, Git, Metadata, Quality, Release,
 * Data, DeploymentStep, Dora, Governance, GovernanceOps and Integration (StoryBoard has its own
 * class). GitHub is mocked with HttpCalloutMock; custom permissions are simulated through
 * GovernanceController.testPermissions so no users are created.
 */
@IsTest
private class CDO_ControllerTests {

    // ------------------------------------------------------------------------------------------
    // Fixtures
    // ------------------------------------------------------------------------------------------

    private class GitHubMock implements HttpCalloutMock {
        private Integer dispatchStatus;
        private Integer getStatus;

        GitHubMock(Integer dispatchStatus, Integer getStatus) {
            this.dispatchStatus = dispatchStatus;
            this.getStatus = getStatus;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().endsWith('/dispatches')) {
                res.setStatusCode(dispatchStatus);
                res.setBody(dispatchStatus == 204 ? '' : '{"message":"Unprocessable Entity"}');
            } else {
                res.setStatusCode(getStatus);
                res.setBody(getStatus == 200 ? '{"full_name":"acme/sf-repo"}' : '{"message":"Not Found"}');
            }
            return res;
        }
    }

    private class UnreachableMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            throw new CalloutException('Unable to tunnel through proxy');
        }
    }

    private class PlainTextMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(503);
            res.setBody('Service Unavailable');
            return res;
        }
    }

    private static void mockGitHub() {
        Test.setMock(HttpCalloutMock.class, new GitHubMock(204, 200));
    }

    private static void grant(List<String> permissions) {
        GovernanceController.testPermissions = new Set<String>(permissions);
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
            Default_Project_Key__c = 'demo'
        );
        CDO_Project__c project = new CDO_Project__c(Name = 'Demo', Key__c = 'demo', Active__c = true, Repository__c = 'acme/sf-repo');
        insert project;

        CDO_Environment__c dev = new CDO_Environment__c(Name = 'Dev', Key__c = 'demo:dev', Project__c = project.Id,
            Pipeline_Key__c = 'dev', Type__c = 'Source', Org_Alias__c = 'sfp-dev');
        CDO_Environment__c intEnv = new CDO_Environment__c(Name = 'Int', Key__c = 'demo:int', Project__c = project.Id,
            Pipeline_Key__c = 'int', Type__c = 'Pipeline', Health_Status__c = 'Healthy', Last_Deployed_On__c = System.now());
        CDO_Environment__c qaEnv = new CDO_Environment__c(Name = 'QA', Key__c = 'demo:qa', Project__c = project.Id,
            Pipeline_Key__c = 'qa', Type__c = 'Pipeline');
        CDO_Environment__c prodEnv = new CDO_Environment__c(Name = 'Prod', Key__c = 'demo:prod', Project__c = project.Id,
            Pipeline_Key__c = 'prod', Type__c = 'Production');
        insert new List<CDO_Environment__c>{ dev, intEnv, qaEnv, prodEnv };

        CDO_Stage__c sInt = new CDO_Stage__c(Name = 'INT', Key__c = 'demo:int', Project__c = project.Id, Environment__c = intEnv.Id,
            Order__c = 1, Is_Entry__c = true, Pipeline_Key__c = 'int', Branch__c = 'int', Gate_Type__c = 'Review', Coverage_Floor__c = 85);
        CDO_Stage__c sQa = new CDO_Stage__c(Name = 'QA', Key__c = 'demo:qa', Project__c = project.Id, Environment__c = qaEnv.Id,
            Order__c = 2, Pipeline_Key__c = 'qa', Branch__c = 'qa', Gate_Type__c = 'Self_Service');
        CDO_Stage__c sProd = new CDO_Stage__c(Name = 'PROD', Key__c = 'demo:prod', Project__c = project.Id, Environment__c = prodEnv.Id,
            Order__c = 3, Is_Production__c = true, Pipeline_Key__c = 'prod', Branch__c = 'main', Gate_Type__c = 'Required_Reviewer');
        insert new List<CDO_Stage__c>{ sInt, sQa, sProd };

        CDO_Work_Item__c approved = new CDO_Work_Item__c(Subject__c = 'Approved change', Status__c = 'Approved', Project__c = project.Id,
            Pull_Requests_Approved__c = true, Last_Commit_SHA__c = 'abc1234', Source_Org_Alias__c = 'dev');
        CDO_Work_Item__c inInt = new CDO_Work_Item__c(Subject__c = 'Change in INT', Status__c = 'Deployed', Project__c = project.Id,
            Current_Stage__c = sInt.Id, Last_Commit_SHA__c = 'def5678', Pull_Request_Number__c = 12,
            Pull_Request_URL__c = 'https://github.com/acme/sf-repo/pull/12', Pull_Requests_Approved__c = true,
            Minimum_Coverage__c = 75, Last_Coverage__c = 90, Last_Validation_Status__c = 'Passed', Developer__c = UserInfo.getUserId());
        CDO_Work_Item__c fresh = new CDO_Work_Item__c(Subject__c = 'Fresh change', Status__c = 'New', Project__c = project.Id);
        insert new List<CDO_Work_Item__c>{ approved, inInt, fresh };

        insert new CDO_Commit__c(Name = 'def5678', Work_Item__c = inInt.Id, SHA__c = 'def5678def5678def5678def5678def5678def5',
            Branch__c = 'feature/x', Message__c = 'First commit', Component_Count__c = 2, Committed_On__c = System.now().addDays(-5));

        String inIntKey = [SELECT Name FROM CDO_Work_Item__c WHERE Id = :inInt.Id].Name;
        String approvedKey = [SELECT Name FROM CDO_Work_Item__c WHERE Id = :approved.Id].Name;
        insert new List<CDO_Component__c>{
            new CDO_Component__c(Name = 'Foo', Work_Item__c = inInt.Id, Metadata_Type__c = 'ApexClass', Member_Name__c = 'Foo',
                Unique_ID__c = 'ApexClass:Foo', Work_Item_Key__c = inIntKey + '|ApexClass:Foo', Action__c = 'Add',
                Path__c = 'force-app/main/default/classes/Foo.cls'),
            new CDO_Component__c(Name = 'Bar__c', Work_Item__c = inInt.Id, Metadata_Type__c = 'CustomObject', Member_Name__c = 'Bar__c',
                Unique_ID__c = 'CustomObject:Bar__c', Work_Item_Key__c = inIntKey + '|CustomObject:Bar__c', Action__c = 'Modify',
                Path__c = 'force-app/main/default/objects/Bar__c/Bar__c.object-meta.xml'),
            new CDO_Component__c(Name = 'Foo', Work_Item__c = approved.Id, Metadata_Type__c = 'ApexClass', Member_Name__c = 'Foo',
                Unique_ID__c = 'ApexClass:Foo', Work_Item_Key__c = approvedKey + '|ApexClass:Foo', Action__c = 'Modify',
                Path__c = 'force-app/main/default/classes/Foo.cls')
        };
    }

    private static CDO_Work_Item__c item(String subject) {
        return [
            SELECT Id, Name, Status__c, Current_Stage__c, Release__c, Source_Org_Alias__c, Source_Changes_Status__c,
                   Project__c, Developer__c, Story_Points__c, Minimum_Coverage__c
            FROM CDO_Work_Item__c WHERE Subject__c = :subject LIMIT 1
        ];
    }

    private static CDO_Stage__c stage(String key) {
        return [SELECT Id, Name, Project__c, Environment__c FROM CDO_Stage__c WHERE Key__c = :key];
    }

    private static CDO_Project__c project() {
        return [SELECT Id FROM CDO_Project__c WHERE Key__c = 'demo'];
    }

    private static void assertFails(String expected, String actualMessage) {
        Assert.isTrue(actualMessage != null && actualMessage.contains(expected), 'Expected "' + expected + '" in: ' + actualMessage);
    }

    // ------------------------------------------------------------------------------------------
    // PipelineController
    // ------------------------------------------------------------------------------------------

    @IsTest
    static void pipelineShowsStagesCountsInFlightAndLatestDeployment() {
        CDO_Stage__c qa = stage('demo:qa');
        CDO_Stage__c intStage = stage('demo:int');
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = project().Id, Source_Stage__c = intStage.Id, Target_Stage__c = qa.Id,
            Status__c = 'Queued');
        insert p;
        insert new CDO_Promoted_Work_Item__c(Promotion__c = p.Id, Work_Item__c = item('Change in INT').Id,
            Unique_Key__c = p.Id + ':' + item('Change in INT').Id);
        CDO_Deployment__c older = new CDO_Deployment__c(Stage__c = intStage.Id, Status__c = 'Failed', Event_Type__c = 'Deploy');
        CDO_Deployment__c newer = new CDO_Deployment__c(Stage__c = intStage.Id, Status__c = 'Success', Event_Type__c = 'Deploy',
            Work_Item__c = item('Change in INT').Id, Coverage_Percent__c = 90);
        insert new List<CDO_Deployment__c>{ older, newer };

        Assert.areEqual(1, PipelineController.getProjects().size());
        PipelineController.PipelineView view = PipelineController.getPipeline(null);

        Assert.isTrue(view.hasStages);
        Assert.areEqual('Demo', view.projectName);
        Assert.areEqual('https://github.com/acme/sf-repo', view.repoUrl);
        Assert.areEqual(3, view.stages.size());
        PipelineController.StageCard intCard = view.stages[0];
        Assert.areEqual('INT', intCard.name);
        Assert.isTrue(intCard.isEntry);
        Assert.areEqual(1, intCard.workItemCount);
        Assert.areEqual(1, intCard.workItems.size());
        Assert.areEqual('Healthy', intCard.healthStatus);
        Assert.isNotNull(intCard.latestDeployment);
        Assert.areEqual(newer.Id, intCard.latestDeployment.id, 'Latest by CreatedDate DESC, Id DESC');
        PipelineController.StageCard qaCard = view.stages[1];
        Assert.areEqual(1, qaCard.inFlight.size());
        Assert.areEqual(1, qaCard.queuedCount);
        Assert.areEqual(1, qaCard.inFlight[0].workItemCount);
        Assert.isTrue(view.stages[2].isProduction);
        Assert.isTrue(view.stages[2].isLast);
        Assert.areEqual(2, view.backlogCount, 'Approved + New, no stage');
        Assert.areEqual(1, view.approvedBacklogCount);
    }

    @IsTest
    static void pipelineEmptyStates() {
        CDO_Project__c empty = new CDO_Project__c(Name = 'Empty', Key__c = 'empty', Active__c = true);
        insert empty;
        PipelineController.PipelineView view = PipelineController.getPipeline(empty.Id);
        Assert.isFalse(view.hasStages);
        Assert.isTrue(view.emptyMessage.contains('No stages configured yet'));

        Assert.isNull(PipelineController.resolveProject(UserInfo.getUserId()), 'Unknown id resolves to nothing');
        Assert.isNull(PipelineController.entryStage(new List<CDO_Stage__c>()));
    }

    @IsTest
    static void pipelineWithoutProjects() {
        delete [SELECT Id FROM CDO_Work_Item__c];
        delete [SELECT Id FROM CDO_Environment__c];
        delete [SELECT Id FROM CDO_Project__c];
        PipelineController.PipelineView view = PipelineController.getPipeline(null);
        Assert.isFalse(view.hasStages);
        Assert.isTrue(view.emptyMessage.contains('seed-pipeline.py'));
    }

    // ------------------------------------------------------------------------------------------
    // PromotionController
    // ------------------------------------------------------------------------------------------

    @IsTest
    static void promoteWorkItemOnlyCreatesDraftWithJunction() {
        grant(new List<String>());
        CDO_Work_Item__c wi = item('Approved change');

        PromotionController.PromotionResult r = PromotionController.promoteWorkItemOnly(wi.Id);

        Assert.areEqual('Draft', r.status);
        Assert.areEqual('INT', r.targetStageName);
        Assert.isFalse(r.dispatched);
        Assert.areEqual(1, r.workItemCount);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Promoted_Work_Item__c WHERE Promotion__c = :r.promotionId AND Work_Item__c = :wi.Id]);

        // A second promotion of the same work item is refused while the first is open.
        try {
            PromotionController.promoteWorkItemOnly(wi.Id);
            Assert.fail('A second open promotion must be refused');
        } catch (AuraHandledException e) {
            assertFails('open promotion', e.getMessage());
        }
    }

    @IsTest
    static void promoteWorkItemQueuesAndDispatches() {
        mockGitHub();
        CDO_Work_Item__c wi = item('Change in INT');

        Test.startTest();
        PromotionController.PromotionResult r = PromotionController.promoteWorkItem(wi.Id);
        Test.stopTest();

        Assert.areEqual('QA', r.targetStageName);
        Assert.isTrue(r.dispatched);
        CDO_Promotion__c p = [SELECT Status__c, Source_Stage__r.Name, Direction__c FROM CDO_Promotion__c WHERE Id = :r.promotionId];
        Assert.isTrue(p.Status__c == 'Queued' || p.Status__c == 'Dispatched', p.Status__c);
        Assert.areEqual('INT', p.Source_Stage__r.Name);
        Assert.areEqual('Forward', p.Direction__c);
    }

    @IsTest
    static void entryStageNeedsApprovedPullRequestOrPermission() {
        CDO_Work_Item__c wi = item('Fresh change');
        update new CDO_Work_Item__c(Id = wi.Id, Status__c = 'Approved', Pull_Requests_Approved__c = false, Last_Commit_SHA__c = 'fff0000');

        grant(new List<String>());
        try {
            PromotionController.promoteWorkItemOnly(wi.Id);
            Assert.fail('The entry gate must refuse');
        } catch (AuraHandledException e) {
            assertFails('approved pull request', e.getMessage());
        }
        PromotionController.PromotionPreview preview = PromotionController.getPromotionPreview(wi.Id);
        Assert.isFalse(preview.canPromote);
        Assert.isTrue(preview.isEntry);

        grant(new List<String>{ GovernanceController.PERM_APPROVE_ENTRY });
        PromotionController.PromotionResult r = PromotionController.promoteWorkItemOnly(wi.Id);
        Assert.areEqual('Draft', r.status);
    }

    @IsTest
    static void promoteRefusesClosedAtProductionAndProjectless() {
        CDO_Work_Item__c wi = item('Change in INT');
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = stage('demo:prod').Id);
        try {
            PromotionController.promoteWorkItem(wi.Id);
            Assert.fail('Nothing after production');
        } catch (AuraHandledException e) {
            assertFails('already at production', e.getMessage());
        }
        Assert.isTrue(PromotionController.getPromotionPreview(wi.Id).blockedReason.contains('production'));

        CDO_Work_Item__c fresh = item('Fresh change');
        update new CDO_Work_Item__c(Id = fresh.Id, Status__c = 'Done');
        try {
            PromotionController.promoteWorkItem(fresh.Id);
            Assert.fail('A Done work item cannot be promoted');
        } catch (AuraHandledException e) {
            assertFails('cannot be promoted', e.getMessage());
        }
        Assert.isFalse(PromotionController.getPromotionPreview(fresh.Id).canPromote);

        update new CDO_Work_Item__c(Id = fresh.Id, Status__c = 'New', Project__c = null);
        try {
            PromotionController.promoteWorkItemOnly(fresh.Id);
            Assert.fail('A work item without a project has no pipeline');
        } catch (AuraHandledException e) {
            assertFails('no project', e.getMessage());
        }
        Assert.isTrue(PromotionController.getPromotionPreview(fresh.Id).blockedReason.contains('no project'));
        Assert.isNotNull(PromotionController.getPromotionPreview(null).blockedReason);
        try {
            PromotionController.promoteWorkItem(null);
            Assert.fail('A work item is required');
        } catch (AuraHandledException e) {
            assertFails('work item', e.getMessage());
        }
    }

    @IsTest
    static void previewShowsNextStage() {
        grant(new List<String>());
        PromotionController.PromotionPreview preview = PromotionController.getPromotionPreview(item('Change in INT').Id);
        Assert.isTrue(preview.canPromote, 'Blocked: ' + preview.blockedReason);
        Assert.areEqual('QA', preview.nextStageName);
        Assert.areEqual('INT', preview.currentStageName);
        Assert.isFalse(preview.isProduction);
    }

    @IsTest
    static void createPromotionValidatesCandidatesAndOptions() {
        grant(new List<String>());
        CDO_Stage__c qa = stage('demo:qa');
        CDO_Work_Item__c inInt = item('Change in INT');
        CDO_Work_Item__c fresh = item('Fresh change');
        update new CDO_Work_Item__c(Id = fresh.Id, Last_Commit_SHA__c = 'fff0000');

        PromotionController.PromotionResult r = PromotionController.createPromotion(new List<Id>{ inInt.Id }, qa.Id, false,
            new Map<String, String>{ 'testLevel' => 'RunLocalTests', 'checkOnly' => 'TRUE', 'specifiedTests' => '  ' });
        CDO_Promotion__c p = [SELECT Status__c, Test_Level__c, Check_Only__c FROM CDO_Promotion__c WHERE Id = :r.promotionId];
        Assert.areEqual('Draft', p.Status__c);
        Assert.areEqual('RunLocalTests', p.Test_Level__c);
        Assert.isTrue(p.Check_Only__c);

        Map<String, String> bad = new Map<String, String>{ 'colour' => 'blue' };
        List<Map<String, String>> badOptions = new List<Map<String, String>>{
            bad,
            new Map<String, String>{ 'testLevel' => 'Everything' },
            new Map<String, String>{ 'checkOnly' => 'maybe' },
            new Map<String, String>{ 'direction' => 'Sideways' }
        };
        for (Map<String, String> opts : badOptions) {
            try {
                PromotionController.createPromotion(new List<Id>{ fresh.Id }, qa.Id, false, opts);
                Assert.fail('Bad options must be refused: ' + opts);
            } catch (AuraHandledException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
        try {
            PromotionController.createPromotion(new List<Id>{ fresh.Id }, qa.Id, false, null);
            Assert.fail('A work item outside the previous stage is not a candidate');
        } catch (AuraHandledException e) {
            assertFails('not INT', e.getMessage());
        }
        try {
            PromotionController.createPromotion(new List<Id>(), qa.Id, true, null);
            Assert.fail('Empty selection');
        } catch (AuraHandledException e) {
            assertFails('Select at least one', e.getMessage());
        }
        try {
            PromotionController.createPromotion(new List<Id>{ fresh.Id }, null, true, null);
            Assert.fail('No stage');
        } catch (AuraHandledException e) {
            assertFails('stage', e.getMessage());
        }
        try {
            PromotionController.createPromotion(new List<Id>{ inInt.Id }, stage('demo:int').Id, false, null);
            Assert.fail('Already in a stage cannot enter the entry stage');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage());
        }
    }

    @IsTest
    static void backPromotionNeedsWorkItemsPastTheTarget() {
        grant(new List<String>());
        CDO_Work_Item__c inQa = new CDO_Work_Item__c(Subject__c = 'In QA', Status__c = 'Deployed', Project__c = project().Id,
            Current_Stage__c = stage('demo:qa').Id, Last_Commit_SHA__c = 'qqq1111');
        insert inQa;
        update new CDO_Work_Item__c(Id = item('Fresh change').Id, Last_Commit_SHA__c = 'fff0000');

        PromotionController.PromotionResult r = PromotionController.createPromotion(new List<Id>{ inQa.Id }, stage('demo:int').Id,
            false, new Map<String, String>{ 'direction' => 'Back' });
        Assert.areEqual('Back', [SELECT Direction__c FROM CDO_Promotion__c WHERE Id = :r.promotionId].Direction__c);

        try {
            PromotionController.createPromotion(new List<Id>{ item('Fresh change').Id }, stage('demo:int').Id, false,
                new Map<String, String>{ 'direction' => 'Back' });
            Assert.fail('A work item with no stage cannot be back-promoted');
        } catch (AuraHandledException e) {
            assertFails('back-promotion', e.getMessage());
        }
    }

    @IsTest
    static void promotionIntoProductionIsRefused() {
        grant(new List<String>());
        CDO_Work_Item__c inQa = new CDO_Work_Item__c(Subject__c = 'In QA', Status__c = 'Deployed', Project__c = project().Id,
            Current_Stage__c = stage('demo:qa').Id, Last_Commit_SHA__c = 'qqq1111');
        insert inQa;
        try {
            PromotionController.promoteWorkItemOnly(inQa.Id);
            Assert.fail('Production ships through a release');
        } catch (AuraHandledException e) {
            assertFails('ships through a release', e.getMessage());
        }
        PromotionController.PromotionPreview preview = PromotionController.getPromotionPreview(inQa.Id);
        Assert.isFalse(preview.canPromote);
        Assert.isTrue(preview.isProduction);
        try {
            PromotionController.createPromotion(new List<Id>{ inQa.Id }, stage('demo:prod').Id, true, null);
            Assert.fail('Production ships through a release');
        } catch (AuraHandledException e) {
            assertFails('ships through a release', e.getMessage());
        }
    }

    @IsTest
    static void promotionNeedsACommit() {
        grant(new List<String>());
        CDO_Work_Item__c fresh = item('Fresh change');
        update new CDO_Work_Item__c(Id = fresh.Id, Status__c = 'Approved', Pull_Requests_Approved__c = true);
        try {
            PromotionController.promoteWorkItemOnly(fresh.Id);
            Assert.fail('Nothing to promote without a commit');
        } catch (AuraHandledException e) {
            assertFails('Commit changes before promoting', e.getMessage());
        }
        // A CDO_Commit__c row counts even before Last_Commit_SHA__c is stamped.
        insert new CDO_Commit__c(Name = 'f1', Work_Item__c = fresh.Id, SHA__c = 'f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1');
        Assert.isTrue(PromotionController.getPromotionPreview(fresh.Id).canPromote);
    }

    @IsTest
    static void lowCoverageHoldsTheDeployButAllowsADraft() {
        grant(new List<String>());
        CDO_Work_Item__c inInt = item('Change in INT');
        update new CDO_Work_Item__c(Id = inInt.Id, Last_Coverage__c = 70);

        PromotionController.PromotionPreview preview = PromotionController.getPromotionPreview(inInt.Id);
        Assert.isTrue(preview.canPromote);
        Assert.isFalse(preview.canDeploy);
        assertFails('below the minimum', preview.deployBlockedReason);
        try {
            PromotionController.promoteWorkItem(inInt.Id);
            Assert.fail('The deploy must be held');
        } catch (AuraHandledException e) {
            assertFails('below the minimum', e.getMessage());
        }
        PromotionController.PromotionResult draft = PromotionController.promoteWorkItemOnly(inInt.Id);
        Assert.areEqual('Draft', draft.status);
        try {
            PromotionController.deployPromotion(draft.promotionId);
            Assert.fail('The deploy must be held');
        } catch (AuraHandledException e) {
            assertFails('below the minimum', e.getMessage());
        }
    }

    @IsTest
    static void deployCancelAndReadPromotion() {
        mockGitHub();
        grant(new List<String>());
        PromotionController.PromotionResult draft = PromotionController.promoteWorkItemOnly(item('Approved change').Id);

        PromotionController.PromotionView view = PromotionController.getPromotion(draft.promotionId);
        Assert.isTrue(view.canDeploy);
        Assert.isTrue(view.canCancel);
        Assert.isTrue(view.isEntry);
        Assert.areEqual(1, view.workItems.size());
        Assert.areEqual('Approved change', view.workItems[0].subject);

        Test.startTest();
        PromotionController.PromotionResult deployed = PromotionController.deployPromotion(draft.promotionId);
        Test.stopTest();
        Assert.isTrue(deployed.status == 'Queued' || deployed.status == 'Dispatched', deployed.status);

        try {
            PromotionController.deployPromotion(draft.promotionId);
            Assert.fail('Only a Draft can be deployed');
        } catch (AuraHandledException e) {
            assertFails('Only a Draft', e.getMessage());
        }

        PromotionController.PromotionResult cancelled = PromotionController.cancelPromotion(draft.promotionId);
        Assert.areEqual('Cancelled', cancelled.status);
        Assert.areEqual('Cancelled', [SELECT Status__c FROM CDO_Promotion__c WHERE Id = :draft.promotionId].Status__c);
    }

    @IsTest
    static void runningPromotionCannotBeCancelled() {
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = project().Id, Target_Stage__c = stage('demo:qa').Id,
            Status__c = 'Deploying', Workflow_Run_URL__c = 'https://github.com/acme/sf-repo/actions/runs/1');
        insert p;
        try {
            PromotionController.cancelPromotion(p.Id);
            Assert.fail('A running promotion cannot be cancelled here');
        } catch (AuraHandledException e) {
            assertFails('running in GitHub', e.getMessage());
        }
        update new CDO_Promotion__c(Id = p.Id, Status__c = 'Deployed');
        try {
            PromotionController.cancelPromotion(p.Id);
            Assert.fail('A finished promotion cannot be cancelled');
        } catch (AuraHandledException e) {
            assertFails('can no longer be cancelled', e.getMessage());
        }
        try {
            PromotionController.deployPromotion(p.Id);
            Assert.fail('A finished promotion cannot be deployed');
        } catch (AuraHandledException e) {
            assertFails('Only a Draft', e.getMessage());
        }
        try {
            PromotionController.getPromotion(null);
            Assert.fail('Missing promotion');
        } catch (AuraHandledException e) {
            assertFails('no longer exists', e.getMessage());
        }
    }

    @IsTest
    static void emptyDraftCannotBeDeployed() {
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = project().Id, Target_Stage__c = stage('demo:qa').Id, Status__c = 'Draft');
        insert p;
        try {
            PromotionController.deployPromotion(p.Id);
            Assert.fail('A promotion without junction rows cannot be deployed');
        } catch (AuraHandledException e) {
            assertFails('carries no work items', e.getMessage());
        }
    }

    @IsTest
    static void candidatesAndStages() {
        grant(new List<String>());
        PromotionController.CandidateView entry = PromotionController.getPromotionCandidates(stage('demo:int').Id);
        Assert.isTrue(entry.isEntry);
        Assert.areEqual(1, entry.candidates.size());
        Assert.areEqual('Approved change', entry.candidates[0].subject);

        PromotionController.promoteWorkItemOnly(item('Approved change').Id);
        entry = PromotionController.getPromotionCandidates(stage('demo:int').Id);
        Assert.areEqual(0, entry.candidates.size());
        Assert.areEqual(1, entry.ineligible.size());
        assertFails('Already in', entry.ineligible[0].reason);

        PromotionController.CandidateView qa = PromotionController.getPromotionCandidates(stage('demo:qa').Id);
        Assert.isFalse(qa.isEntry);
        Assert.areEqual('INT', qa.previousStageName);
        Assert.areEqual(1, qa.candidates.size());
        Assert.areEqual('Change in INT', qa.candidates[0].subject);

        Assert.isNull(PromotionController.getPromotionCandidates(null).targetStageId);
        List<PromotionController.StageOption> stages = PromotionController.getStages(null);
        Assert.areEqual(2, stages.size(), 'Production is not a promotion target');
        Assert.isTrue(stages[0].isEntry);
        Assert.isTrue(stages[0].label.contains('entry'));

        PromotionController.CandidateView prod = PromotionController.getPromotionCandidates(stage('demo:prod').Id);
        Assert.isTrue(prod.isProduction);
        assertFails('ships through a release', prod.message);
        Assert.isTrue(prod.candidates.isEmpty());
    }

    @IsTest
    static void entryCandidatesWithoutApprovalAreIneligible() {
        grant(new List<String>());
        CDO_Work_Item__c fresh = item('Fresh change');
        update new CDO_Work_Item__c(Id = fresh.Id, Status__c = 'Approved');
        PromotionController.CandidateView entry = PromotionController.getPromotionCandidates(stage('demo:int').Id);
        Assert.areEqual(1, entry.candidates.size());
        Assert.areEqual(1, entry.ineligible.size());
        assertFails('No commits yet', entry.ineligible[0].reason);

        update new CDO_Work_Item__c(Id = fresh.Id, Last_Commit_SHA__c = 'fff0000');
        entry = PromotionController.getPromotionCandidates(stage('demo:int').Id);
        Assert.areEqual(1, entry.ineligible.size());
        assertFails('approved pull request', entry.ineligible[0].reason);
    }

    // ------------------------------------------------------------------------------------------
    // WorkItemController
    // ------------------------------------------------------------------------------------------

    @IsTest
    static void createWorkItemCoercesAllowedFields() {
        Id newId = WorkItemController.createWorkItem(new Map<String, Object>{
            'Subject__c' => 'Created from the form',
            'Story_Points__c' => 5,
            'Minimum_Coverage__c' => '80',
            'Project__c' => String.valueOf(project().Id),
            'Test_Level_Override__c' => 'RunLocalTests',
            'Description__c' => ''
        });
        CDO_Work_Item__c wi = [
            SELECT Subject__c, Story_Points__c, Minimum_Coverage__c, Project__c, Developer__c, Status__c, Current_Stage__c, Description__c
            FROM CDO_Work_Item__c WHERE Id = :newId
        ];
        Assert.areEqual(5, wi.Story_Points__c);
        Assert.areEqual(80, wi.Minimum_Coverage__c, 'Percent is stored literally');
        Assert.areEqual(project().Id, wi.Project__c);
        Assert.areEqual(UserInfo.getUserId(), wi.Developer__c, 'Developer defaults to the creator');
        Assert.areEqual('New', wi.Status__c);
        Assert.isNull(wi.Current_Stage__c);
        Assert.isNull(wi.Description__c);
    }

    @IsTest
    static void createWorkItemRejectsBadInput() {
        List<Map<String, Object>> inputs = new List<Map<String, Object>>{
            null,
            new Map<String, Object>{ 'Subject__c' => '  ' },
            new Map<String, Object>{ 'Subject__c' => 'x', 'Status__c' => 'Done' },
            new Map<String, Object>{ 'Subject__c' => 'x', 'Story_Points__c' => 'lots' }
        };
        for (Map<String, Object> fields : inputs) {
            try {
                WorkItemController.createWorkItem(fields);
                Assert.fail('Must be refused: ' + fields);
            } catch (AuraHandledException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
    }

    @IsTest
    static void readAndUpdateWorkItems() {
        CDO_Work_Item__c wi = item('Fresh change');
        Assert.areEqual('Fresh change', WorkItemController.getWorkItem(wi.Id).Subject__c);
        Assert.isNull(WorkItemController.getWorkItem(null));
        Assert.areEqual(3, WorkItemController.getMyWorkItems().size());
        List<CDO_Environment__c> sources = WorkItemController.getSourceOrgs();
        Assert.areEqual(1, sources.size());
        Assert.areEqual('dev', sources[0].Pipeline_Key__c);

        grant(new List<String>());
        CDO_Work_Item__c updated = WorkItemController.updateStatus(wi.Id, 'In Progress');
        Assert.areEqual('In_Progress', updated.Status__c);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Work_Item__c = :wi.Id AND Event_Type__c = 'Status']);
        Assert.areEqual('In_Progress', WorkItemController.updateStatus(wi.Id, 'In_Progress').Status__c, 'No-op when unchanged');

        update new CDO_Work_Item__c(Id = wi.Id, Status__c = 'Blocked', Blocked_Reason__c = 'Broken');
        Assert.isNull(WorkItemController.updateStatus(wi.Id, 'New').Blocked_Reason__c, 'Unblocking clears the reason');

        for (String status : new List<String>{ 'Committed', 'Approved', '' }) {
            try {
                WorkItemController.updateStatus(wi.Id, status);
                Assert.fail('Must be refused: ' + status);
            } catch (AuraHandledException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
        grant(new List<String>{ GovernanceController.PERM_APPROVE_ENTRY });
        Assert.areEqual('Approved', WorkItemController.updateStatus(wi.Id, 'Approved').Status__c);

        delete new CDO_Work_Item__c(Id = wi.Id);
        try {
            WorkItemController.updateStatus(wi.Id, 'New');
            Assert.fail('Deleted work item');
        } catch (AuraHandledException e) {
            assertFails('no longer exists', e.getMessage());
        }
    }

    // ------------------------------------------------------------------------------------------
    // GitController
    // ------------------------------------------------------------------------------------------

    @IsTest
    static void listChangesRequestsAndRemembersTheSourceOrg() {
        mockGitHub();
        CDO_Work_Item__c wi = item('Fresh change');

        Test.startTest();
        String requestId = GitController.requestListChanges(wi.Id, 'dev');
        Test.stopTest();

        Assert.isTrue(String.isNotBlank(requestId));
        CDO_Work_Item__c after = item('Fresh change');
        Assert.areEqual('dev', after.Source_Org_Alias__c);
        Assert.areEqual('Requested', after.Source_Changes_Status__c);

        try {
            GitController.requestListChanges(item('Change in INT').Id, '');
            Assert.fail('A source org is needed');
        } catch (AuraHandledException e) {
            assertFails('source org', e.getMessage());
        }
    }

    @IsTest
    static void listChangesParsesNewestFirstAndFlagsCommitted() {
        CDO_Work_Item__c wi = item('Change in INT');
        update new CDO_Work_Item__c(
            Id = wi.Id,
            Source_Changes_Status__c = 'Received',
            Source_Changes_Received_On__c = System.now(),
            Source_Changes_JSON__c = '[{"type":"ApexClass","name":"Old","lastModifiedDate":"2026-10-01T10:00:00.000Z","lastModifiedBy":"Ann","state":"Changed"},' +
                '{"type":"ApexClass","name":"Foo","lastModifiedDate":"2026-10-12T10:00:00.000Z","lastModifiedBy":"Bo","state":"Changed"},' +
                '{"type":"","name":"skipped"}]'
        );
        GitController.ListChangesView view = GitController.getListChanges(wi.Id);
        Assert.areEqual('Received', view.status);
        Assert.areEqual(2, view.total);
        Assert.areEqual('Foo', view.members[0].name, 'Newest first');
        Assert.isTrue(view.members[0].alreadyCommitted);
        Assert.isFalse(view.members[1].alreadyCommitted);

        update new CDO_Work_Item__c(Id = wi.Id,
            Source_Changes_JSON__c = '{"sourceOrg":"dev","message":"2 members","members":[{"type":"Flow","name":"F1","lastModifiedDate":"2026-10-02"}]}');
        view = GitController.getListChanges(wi.Id);
        Assert.areEqual(1, view.total);
        Assert.areEqual('dev', view.sourceOrg);
        Assert.areEqual('2 members', view.message);

        update new CDO_Work_Item__c(Id = wi.Id, Source_Changes_JSON__c = '{not json');
        view = GitController.getListChanges(wi.Id);
        Assert.areEqual(0, view.total);
        assertFails('could not be read', view.message);
    }

    @IsTest
    static void commitComponentsValidatesTheSelection() {
        mockGitHub();
        CDO_Work_Item__c wi = item('Change in INT');

        Test.startTest();
        String message = GitController.commitComponents(wi.Id,
            '[{"type":"ApexClass","name":"Foo"},{"type":"ApexClass","name":"Foo"},{"type":"CustomObject","name":"Bar__c"}]', 'Add Foo');
        Test.stopTest();
        assertFails('2 components', message);

        Map<String, String> bad = new Map<String, String>{
            '' => 'Select at least one component',
            '[]' => 'Select at least one component',
            '{bad' => 'not valid JSON',
            '[{"type":"ApexClass"}]' => 'type and a name'
        };
        for (String json : bad.keySet()) {
            try {
                GitController.commitComponents(wi.Id, json, 'msg');
                Assert.fail('Must be refused: ' + json);
            } catch (AuraHandledException e) {
                assertFails(bad.get(json), e.getMessage());
            }
        }
        try {
            GitController.commitComponents(wi.Id, '[{"type":"ApexClass","name":"Foo"}]', ' ');
            Assert.fail('A message is needed');
        } catch (AuraHandledException e) {
            assertFails('commit message', e.getMessage());
        }
    }

    @IsTest
    static void pullRequestAndValidationRules() {
        mockGitHub();
        CDO_Work_Item__c approved = item('Approved change');
        CDO_Work_Item__c inInt = item('Change in INT');
        CDO_Work_Item__c fresh = item('Fresh change');

        Test.startTest();
        assertFails('Pull request requested', GitController.openPullRequest(approved.Id));
        assertFails('Validation requested', GitController.requestValidation(inInt.Id));
        Test.stopTest();

        try {
            GitController.openPullRequest(inInt.Id);
            Assert.fail('Already has a pull request');
        } catch (AuraHandledException e) {
            assertFails('already has a pull request', e.getMessage());
        }
        for (Integer i = 0; i < 2; i++) {
            try {
                if (i == 0) {
                    GitController.openPullRequest(fresh.Id);
                } else {
                    GitController.requestValidation(fresh.Id);
                }
                Assert.fail('Commit first');
            } catch (AuraHandledException e) {
                assertFails('Commit components', e.getMessage());
            }
        }
        update new CDO_Work_Item__c(Id = inInt.Id, Last_Validation_Status__c = 'Running', Last_Run_URL__c = 'https://github.com/x/runs/1');
        try {
            GitController.requestValidation(inInt.Id);
            Assert.fail('Already running');
        } catch (AuraHandledException e) {
            assertFails('already running', e.getMessage());
        }
        try {
            GitController.requestValidation(approved.Id);
            Assert.fail('The service needs a pull request first');
        } catch (AuraHandledException e) {
            assertFails('pull request', e.getMessage());
        }
        Assert.areEqual(1, GitController.getCommits(inInt.Id).size());
        Assert.isTrue(GitController.getCommits(null).isEmpty());
        try {
            GitController.getListChanges(null);
            Assert.fail('Missing work item');
        } catch (AuraHandledException e) {
            assertFails('no longer exists', e.getMessage());
        }
    }

    // ------------------------------------------------------------------------------------------
    // MetadataController
    // ------------------------------------------------------------------------------------------

    @IsTest
    static void componentsOverlapsAndDependencies() {
        CDO_Work_Item__c inInt = item('Change in INT');
        List<CDO_Component__c> components = MetadataController.getComponents(inInt.Id);
        Assert.areEqual(2, components.size());
        Assert.isTrue(MetadataController.getComponents(null).isEmpty());

        List<MetadataController.Overlap> overlaps = MetadataController.getOverlaps(inInt.Id);
        Assert.areEqual(1, overlaps.size());
        Assert.areEqual('ApexClass:Foo', overlaps[0].uniqueId);
        Assert.areEqual('Approved change', overlaps[0].workItems[0].subject);
        Assert.isTrue(MetadataController.getOverlaps(null).isEmpty());
        Assert.isTrue(MetadataController.getOverlaps(item('Fresh change').Id).isEmpty());

        CDO_Component__c foo;
        CDO_Component__c bar;
        for (CDO_Component__c c : components) {
            if (c.Unique_ID__c == 'ApexClass:Foo') {
                foo = c;
            } else {
                bar = c;
            }
        }
        insert new List<CDO_Component_Dependency__c>{
            new CDO_Component_Dependency__c(Component__c = foo.Id, Depends_On__c = bar.Id, Dependency_Type__c = 'Reference'),
            new CDO_Component_Dependency__c(Component__c = foo.Id, Depends_On_Unique_ID__c = 'CustomField:Account.X__c', Dependency_Type__c = 'Field')
        };
        MetadataController.DependencyView fooDeps = MetadataController.getDependencies(foo.Id);
        Assert.areEqual(2, fooDeps.dependsOn.size());
        MetadataController.DependencyView barDeps = MetadataController.getDependencies(bar.Id);
        Assert.areEqual(1, barDeps.dependents.size());
        Assert.areEqual('ApexClass:Foo', barDeps.dependents[0].uniqueId);
        Assert.isNull(MetadataController.getDependencies(null).componentId);
    }

    @IsTest
    static void removeComponentAudits() {
        CDO_Work_Item__c inInt = item('Change in INT');
        CDO_Component__c bar = [SELECT Id FROM CDO_Component__c WHERE Work_Item__c = :inInt.Id AND Unique_ID__c = 'CustomObject:Bar__c'];
        assertFails('removed', MetadataController.removeComponent(bar.Id));
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Component__c WHERE Work_Item__c = :inInt.Id]);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = 'Component' AND Work_Item__c = :inInt.Id]);

        update new CDO_Work_Item__c(Id = inInt.Id, Status__c = 'Promoting');
        CDO_Component__c foo = [SELECT Id FROM CDO_Component__c WHERE Work_Item__c = :inInt.Id];
        try {
            MetadataController.removeComponent(foo.Id);
            Assert.fail('Not while promoting');
        } catch (AuraHandledException e) {
            assertFails('being promoted', e.getMessage());
        }
        try {
            MetadataController.removeComponent(null);
            Assert.fail('Missing component');
        } catch (AuraHandledException e) {
            assertFails('no longer exists', e.getMessage());
        }
    }

    // ------------------------------------------------------------------------------------------
    // QualityController
    // ------------------------------------------------------------------------------------------

    @IsTest
    static void findingsAndValidation() {
        CDO_Work_Item__c inInt = item('Change in INT');
        update new CDO_Work_Item__c(Id = inInt.Id, Last_Coverage__c = 70);
        insert new List<CDO_Scan_Finding__c>{
            new CDO_Scan_Finding__c(Work_Item__c = inInt.Id, Tool__c = 'PMD', Rule__c = 'ApexCRUDViolation', Severity__c = 'Low', File__c = 'Foo.cls', Line__c = 3),
            new CDO_Scan_Finding__c(Work_Item__c = inInt.Id, Tool__c = 'PMD', Rule__c = 'ApexSOQLInjection', Severity__c = 'Critical', File__c = 'Foo.cls', Line__c = 9)
        };
        insert new CDO_Deployment__c(Work_Item__c = inInt.Id, Stage__c = stage('demo:int').Id, Status__c = 'Failed',
            Event_Type__c = 'Validation', Check_Only__c = true, Coverage_Percent__c = 70,
            Failing_Methods__c = 'FooTest.one: boom\n\nFooTest.two: bang');

        QualityController.FindingsView findings = QualityController.getFindings(inInt.Id);
        Assert.areEqual(2, findings.total);
        Assert.areEqual(1, findings.blocking);
        Assert.areEqual('Critical', findings.findings[0].Severity__c, 'Most severe first');
        Assert.areEqual(0, QualityController.getFindings(null).total);

        QualityController.ValidationView v = QualityController.getLatestValidation(inInt.Id);
        Assert.isNotNull(v.deployment);
        Assert.areEqual(2, v.failingMethods.size());
        Assert.isTrue(v.belowMinimum, '70 < 75');
        Assert.areEqual(75, v.minimumCoverage);
        Assert.isNull(QualityController.getLatestValidation(null).deployment);
        Assert.isNull(QualityController.getLatestValidation(UserInfo.getUserId()).status);
    }

    @IsTest
    static void manualTestScriptsAndResults() {
        CDO_Work_Item__c inInt = item('Change in INT');
        CDO_Test_Script__c script = new CDO_Test_Script__c(Name = 'Login works', Work_Item__c = inInt.Id, Steps__c = '1. Log in', Order__c = 1);
        insert script;

        List<QualityController.TestScriptRow> rows = QualityController.getTestScripts(inInt.Id);
        Assert.areEqual(1, rows.size());
        Assert.areEqual('Not_Run', rows[0].lastOutcome);

        Id resultId = QualityController.recordTestResult(script.Id, 'Pass', 'Fine');
        CDO_Test_Result__c r = [SELECT Outcome__c, Stage__c, Tested_By__c FROM CDO_Test_Result__c WHERE Id = :resultId];
        Assert.areEqual('Pass', r.Outcome__c);
        Assert.areEqual(inInt.Current_Stage__c, r.Stage__c, 'Recorded against the current stage');
        Assert.areEqual(UserInfo.getUserId(), r.Tested_By__c);
        Assert.areEqual('Pass', QualityController.getTestScripts(inInt.Id)[0].lastOutcome);
        Assert.isTrue(QualityController.getTestScripts(null).isEmpty());

        Map<String, String> bad = new Map<String, String>{ 'Great' => 'Outcome must be', 'Fail' => 'what failed' };
        for (String outcome : bad.keySet()) {
            try {
                QualityController.recordTestResult(script.Id, outcome, null);
                Assert.fail('Must be refused: ' + outcome);
            } catch (AuraHandledException e) {
                assertFails(bad.get(outcome), e.getMessage());
            }
        }
        try {
            QualityController.recordTestResult(null, 'Pass', null);
            Assert.fail('Missing script');
        } catch (AuraHandledException e) {
            assertFails('no longer exists', e.getMessage());
        }
    }

    // ------------------------------------------------------------------------------------------
    // ReleaseController
    // ------------------------------------------------------------------------------------------

    @IsTest
    static void releaseLifecycleWithoutDispatch() {
        Id releaseId = ReleaseController.createRelease('Oct release', null, Date.today().addDays(7));
        CDO_Work_Item__c inInt = item('Change in INT');
        CDO_Work_Item__c fresh = item('Fresh change');

        Assert.areEqual(3, ReleaseController.getAvailableWorkItems(null).size(), 'Three open work items, none in a release');
        Assert.areEqual(2, ReleaseController.addWorkItems(releaseId, new List<Id>{ inInt.Id, fresh.Id }));
        Assert.areEqual(0, ReleaseController.addWorkItems(releaseId, new List<Id>{ inInt.Id }), 'Already in the release');
        List<ReleaseController.ReleaseView> releases = ReleaseController.getReleases(project().Id);
        Assert.areEqual(1, releases.size());
        Assert.areEqual(2, releases[0].workItemCount);
        Assert.isTrue(releases[0].canAssemble);
        Assert.isFalse(releases[0].canRelease);
        Assert.areEqual(1, ReleaseController.getReleases(null).size());
        Assert.areEqual(1, ReleaseController.getAvailableWorkItems(null).size());

        ReleaseController.removeWorkItem(fresh.Id);
        Assert.isNull(item('Fresh change').Release__c);
        ReleaseController.removeWorkItem(fresh.Id); // no-op when not in a release

        update new CDO_Release__c(Id = releaseId, Status__c = 'Released');
        try {
            ReleaseController.addWorkItems(releaseId, new List<Id>{ fresh.Id });
            Assert.fail('Released releases are locked');
        } catch (AuraHandledException e) {
            assertFails('can no longer be added', e.getMessage());
        }
        try {
            ReleaseController.removeWorkItem(inInt.Id);
            Assert.fail('Released releases are locked');
        } catch (AuraHandledException e) {
            assertFails('can no longer be removed', e.getMessage());
        }
        for (Integer i = 0; i < 4; i++) {
            try {
                if (i == 0) {
                    ReleaseController.createRelease(' ', null, null);
                } else if (i == 1) {
                    ReleaseController.addWorkItems(releaseId, new List<Id>());
                } else if (i == 2) {
                    ReleaseController.removeWorkItem(null);
                } else {
                    ReleaseController.assembleRelease(null);
                }
                Assert.fail('Must be refused: ' + i);
            } catch (AuraHandledException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
    }

    @IsTest
    static void assembleReleaseDispatches() {
        CDO_Release__c rel = new CDO_Release__c(Name = 'R-assemble', Project__c = project().Id, Status__c = 'Planned');
        insert rel;
        update new CDO_Work_Item__c(Id = item('Change in INT').Id, Release__c = rel.Id);

        // DML stays outside startTest/stopTest so the synchronous callout is allowed.
        Test.startTest();
        mockGitHub();
        String message = ReleaseController.assembleRelease(rel.Id);
        Test.stopTest();

        assertFails('Assembling R-assemble', message);
        Assert.areEqual('Assembling', [SELECT Status__c FROM CDO_Release__c WHERE Id = :rel.Id].Status__c);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Release__c = :rel.Id AND Event_Type__c = 'Release']);
    }

    @IsTest
    static void assembleReleaseReportsGitHubRefusal() {
        CDO_Release__c rel = new CDO_Release__c(Name = 'R-refused', Project__c = project().Id, Status__c = 'Planned');
        insert rel;
        update new CDO_Work_Item__c(Id = item('Change in INT').Id, Release__c = rel.Id);
        CDO_Release__c empty = new CDO_Release__c(Name = 'R-empty', Project__c = project().Id, Status__c = 'Planned');
        insert empty;

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new GitHubMock(422, 200));
        try {
            ReleaseController.assembleRelease(rel.Id);
            Assert.fail('A refused dispatch must surface');
        } catch (AuraHandledException e) {
            assertFails('HTTP 422', e.getMessage());
        }
        Test.stopTest();
        Assert.areEqual('Planned', [SELECT Status__c FROM CDO_Release__c WHERE Id = :rel.Id].Status__c, 'Nothing written');
        try {
            ReleaseController.assembleRelease(empty.Id);
            Assert.fail('Nothing to assemble');
        } catch (AuraHandledException e) {
            assertFails('Add work items', e.getMessage());
        }
        update new CDO_Release__c(Id = empty.Id, Status__c = 'Releasing');
        try {
            ReleaseController.assembleRelease(empty.Id);
            Assert.fail('Wrong status');
        } catch (AuraHandledException e) {
            assertFails('can be assembled', e.getMessage());
        }
    }

    @IsTest
    static void releaseToProductionNeedsPermissionAndAssembly() {
        CDO_Release__c rel = new CDO_Release__c(Name = 'R-prod', Project__c = project().Id, Status__c = 'Planned');
        insert rel;
        update new CDO_Work_Item__c(Id = item('Change in INT').Id, Release__c = rel.Id, Specified_Tests__c = 'FooTest, BarTest');

        grant(new List<String>());
        try {
            ReleaseController.releaseToProduction(rel.Id);
            Assert.fail('Needs CDO_Run_Prod_Release');
        } catch (AuraHandledException e) {
            assertFails(GovernanceController.PERM_RUN_PROD_RELEASE, e.getMessage());
        }
        grant(new List<String>{ GovernanceController.PERM_RUN_PROD_RELEASE });
        try {
            ReleaseController.releaseToProduction(rel.Id);
            Assert.fail('Not assembled yet');
        } catch (AuraHandledException e) {
            assertFails('Assemble it first', e.getMessage());
        }
        update new CDO_Release__c(Id = rel.Id, Status__c = 'Ready');
        try {
            ReleaseController.releaseToProduction(rel.Id);
            Assert.fail('No branch yet');
        } catch (AuraHandledException e) {
            assertFails('no release branch', e.getMessage());
        }
        update new CDO_Release__c(Id = rel.Id, Release_Branch__c = 'release/R-prod');

        Test.startTest();
        mockGitHub();
        String message = ReleaseController.releaseToProduction(rel.Id);
        Test.stopTest();

        assertFails('validating', message);
        Assert.areEqual('Validating', [SELECT Status__c FROM CDO_Release__c WHERE Id = :rel.Id].Status__c);
        ReleaseController.ReleaseView view = ReleaseController.getReleases(null)[0];
        Assert.isTrue(view.locked);
    }

    // ------------------------------------------------------------------------------------------
    // DataController
    // ------------------------------------------------------------------------------------------

    private static CDO_Data_Set__c dataSetWithTemplates() {
        CDO_Data_Set__c ds = new CDO_Data_Set__c(Name = 'Accounts with contacts', Project__c = project().Id, Status__c = 'Ready',
            Source_Environment__c = [SELECT Id FROM CDO_Environment__c WHERE Key__c = 'demo:int'].Id,
            Target_Environment__c = [SELECT Id FROM CDO_Environment__c WHERE Key__c = 'demo:qa'].Id);
        insert ds;
        CDO_Data_Template__c accounts = new CDO_Data_Template__c(Name = 'Accounts', Data_Set__c = ds.Id, Object_API_Name__c = 'Account',
            Fields__c = 'Name,Industry', Filter__c = 'Industry != null', External_Id_Field__c = 'Name', Order__c = 1, Record_Limit__c = 200);
        CDO_Data_Template__c contacts = new CDO_Data_Template__c(Name = 'Contacts', Data_Set__c = ds.Id, Object_API_Name__c = 'Contact',
            Fields__c = 'LastName, Email', Order__c = 2);
        insert new List<CDO_Data_Template__c>{ accounts, contacts };
        insert new CDO_Data_Relationship__c(Data_Set__c = ds.Id, Parent_Template__c = accounts.Id, Child_Template__c = contacts.Id,
            Relationship_Field__c = 'AccountId');
        return ds;
    }

    @IsTest
    static void dataSetReadsAndPlan() {
        CDO_Data_Set__c ds = dataSetWithTemplates();
        Assert.areEqual(1, DataController.getDataSets().size());
        DataController.DataSetView view = DataController.getDataSet(ds.Id);
        Assert.areEqual(2, view.templates.size());
        Assert.areEqual(1, view.relationships.size());
        Assert.isNull(DataController.getDataSet(null).dataSet);
        Assert.isNull(DataController.getDataSet(UserInfo.getUserId()).dataSet);
        Assert.areEqual(4, DataController.getEnvironments().size(), 'Four keyed environments');

        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            DataController.buildPlanJson(view.dataSet, view.templates, view.relationships));
        Assert.areEqual('Accounts with contacts', plan.get('dataSet'));
        List<Object> templates = (List<Object>) plan.get('templates');
        Map<String, Object> first = (Map<String, Object>) templates[0];
        Assert.areEqual('Account', first.get('object'));
        Assert.areEqual(2, ((List<Object>) first.get('fields')).size());
        Assert.areEqual('Name', first.get('externalId'));
        Assert.areEqual(200, first.get('limit'));
        Map<String, Object> rel = (Map<String, Object>) ((List<Object>) plan.get('relationships'))[0];
        Assert.areEqual('Accounts', rel.get('parent'));
        Assert.areEqual('Contacts', rel.get('child'));
        Assert.areEqual('AccountId', rel.get('field'));
    }

    @IsTest
    static void saveAndDeleteTemplates() {
        CDO_Data_Set__c ds = dataSetWithTemplates();
        Id newId = DataController.saveTemplate(new CDO_Data_Template__c(Data_Set__c = ds.Id, Object_API_Name__c = 'Opportunity',
            Fields__c = 'Name StageName, Name', Filter__c = 'WHERE Amount > 0'));
        CDO_Data_Template__c t = [SELECT Name, Fields__c, Filter__c FROM CDO_Data_Template__c WHERE Id = :newId];
        Assert.areEqual('Opportunity', t.Name, 'Name defaults to the object');
        Assert.areEqual('Name,StageName', t.Fields__c);
        Assert.areEqual('Amount > 0', t.Filter__c);

        DataController.saveTemplate(new CDO_Data_Template__c(Id = newId, Name = 'Opps', Object_API_Name__c = 'Ext_Thing__x', Fields__c = 'A__c'));
        Assert.areEqual('Opps', [SELECT Name FROM CDO_Data_Template__c WHERE Id = :newId].Name, 'Unknown objects are accepted as typed');

        List<CDO_Data_Template__c> bad = new List<CDO_Data_Template__c>{
            null,
            new CDO_Data_Template__c(Object_API_Name__c = 'Account', Fields__c = 'Name'),
            new CDO_Data_Template__c(Data_Set__c = ds.Id, Fields__c = 'Name'),
            new CDO_Data_Template__c(Data_Set__c = ds.Id, Object_API_Name__c = 'Account'),
            new CDO_Data_Template__c(Data_Set__c = ds.Id, Object_API_Name__c = 'Account', Fields__c = 'Name', Record_Limit__c = -1),
            new CDO_Data_Template__c(Data_Set__c = ds.Id, Object_API_Name__c = 'Account', Fields__c = 'Name, NoSuchField__c'),
            new CDO_Data_Template__c(Data_Set__c = ds.Id, Object_API_Name__c = 'Account', Fields__c = 'Name', External_Id_Field__c = 'Nope__c'),
            new CDO_Data_Template__c(Data_Set__c = ds.Id, Object_API_Name__c = 'Account', Fields__c = 'Name', External_Id_Field__c = 'Industry')
        };
        for (CDO_Data_Template__c t2 : bad) {
            try {
                DataController.saveTemplate(t2);
                Assert.fail('Must be refused: ' + t2);
            } catch (AuraHandledException e) {
                Assert.isNotNull(e.getMessage());
            }
        }

        CDO_Data_Template__c accounts = [SELECT Id FROM CDO_Data_Template__c WHERE Name = 'Accounts'];
        DataController.deleteTemplate(accounts.Id);
        Assert.areEqual(0, [SELECT COUNT() FROM CDO_Data_Relationship__c WHERE Data_Set__c = :ds.Id], 'Its relationships go too');
        DataController.deleteTemplate(null);
    }

    @IsTest
    static void deployDataSetDispatchesThePlan() {
        CDO_Data_Set__c ds = dataSetWithTemplates();
        CDO_Data_Set__c bare = new CDO_Data_Set__c(Name = 'Bare', Status__c = 'Draft');
        insert bare;

        for (Integer i = 0; i < 3; i++) {
            try {
                if (i == 0) {
                    DataController.deployDataSet(ds.Id, 'int', 'int');
                } else if (i == 1) {
                    DataController.deployDataSet(bare.Id, 'int', 'qa');
                } else {
                    DataController.deployDataSet(bare.Id, null, null);
                }
                Assert.fail('Must be refused: ' + i);
            } catch (AuraHandledException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
        Test.startTest();
        mockGitHub();
        String message = DataController.deployDataSet(ds.Id, null, null);
        Test.stopTest();

        assertFails('from int to qa', message);
        Assert.areEqual('Deploying', [SELECT Status__c FROM CDO_Data_Set__c WHERE Id = :ds.Id].Status__c);
        try {
            DataController.deployDataSet(ds.Id, null, null);
            Assert.fail('Already deploying');
        } catch (AuraHandledException e) {
            assertFails('already deploying', e.getMessage());
        }
        try {
            DataController.deployDataSet(null, 'int', 'qa');
            Assert.fail('Missing data set');
        } catch (AuraHandledException e) {
            assertFails('no longer exists', e.getMessage());
        }
    }

    // ------------------------------------------------------------------------------------------
    // DeploymentStepController
    // ------------------------------------------------------------------------------------------

    @IsTest
    static void deploymentStepLifecycle() {
        CDO_Work_Item__c wi = item('Change in INT');
        Id first = DeploymentStepController.saveStep(new CDO_Deployment_Step__c(Work_Item__c = wi.Id, Instructions__c = 'Disable   the\nscheduler'));
        Id second = DeploymentStepController.saveStep(new CDO_Deployment_Step__c(Work_Item__c = wi.Id, Name = 'Load data', Type__c = 'Data'));
        Id post = DeploymentStepController.saveStep(new CDO_Deployment_Step__c(Work_Item__c = wi.Id, Name = 'Re-enable', Phase__c = 'Post'));

        List<CDO_Deployment_Step__c> steps = DeploymentStepController.getSteps(wi.Id);
        Assert.areEqual(3, steps.size());
        Assert.areEqual('Disable the scheduler', steps[0].Name, 'Name defaults to the instructions');
        Assert.areEqual(1, steps[0].Order__c);
        Assert.areEqual(2, steps[1].Order__c);
        Assert.areEqual('Post', steps[2].Phase__c);
        Assert.areEqual(1, steps[2].Order__c, 'Order counts per phase');
        Assert.isTrue(DeploymentStepController.getSteps(null).isEmpty());

        DeploymentStepController.saveStep(new CDO_Deployment_Step__c(Id = second, Name = 'Load reference data', Status__c = 'In_Progress', Order__c = 5));
        CDO_Deployment_Step__c s2 = [SELECT Name, Status__c, Order__c, Type__c FROM CDO_Deployment_Step__c WHERE Id = :second];
        Assert.areEqual('In_Progress', s2.Status__c);
        Assert.areEqual(5, s2.Order__c);
        Assert.areEqual('Data', s2.Type__c, 'Type kept when not given');

        DeploymentStepController.reorder(new List<Id>{ second, first });
        Assert.areEqual(1, [SELECT Order__c FROM CDO_Deployment_Step__c WHERE Id = :second].Order__c);
        DeploymentStepController.reorder(null);

        CDO_Deployment_Step__c done = DeploymentStepController.completeStep(first);
        Assert.areEqual('Done', done.Status__c);
        Assert.areEqual(UserInfo.getUserId(), done.Completed_By__c);
        Assert.areEqual('Done', DeploymentStepController.completeStep(first).Status__c, 'Completing twice is harmless');
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = 'Deployment Step']);

        try {
            DeploymentStepController.deleteStep(first);
            Assert.fail('Done steps are kept');
        } catch (AuraHandledException e) {
            assertFails('cannot be deleted', e.getMessage());
        }
        DeploymentStepController.deleteStep(post);
        Assert.areEqual(2, DeploymentStepController.getSteps(wi.Id).size());
    }

    @IsTest
    static void deploymentStepValidation() {
        CDO_Work_Item__c wi = item('Change in INT');
        CDO_Work_Item__c other = item('Fresh change');
        Id a = DeploymentStepController.saveStep(new CDO_Deployment_Step__c(Work_Item__c = wi.Id, Name = 'A'));
        Id b = DeploymentStepController.saveStep(new CDO_Deployment_Step__c(Work_Item__c = other.Id, Name = 'B'));

        List<CDO_Deployment_Step__c> bad = new List<CDO_Deployment_Step__c>{
            null,
            new CDO_Deployment_Step__c(Name = 'No work item'),
            new CDO_Deployment_Step__c(Work_Item__c = wi.Id, Name = 'x', Phase__c = 'During'),
            new CDO_Deployment_Step__c(Work_Item__c = wi.Id, Name = 'x', Type__c = 'Magic'),
            new CDO_Deployment_Step__c(Work_Item__c = wi.Id),
            new CDO_Deployment_Step__c(Id = a, Name = 'A', Status__c = 'Done')
        };
        for (CDO_Deployment_Step__c s : bad) {
            try {
                DeploymentStepController.saveStep(s);
                Assert.fail('Must be refused: ' + s);
            } catch (AuraHandledException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
        try {
            DeploymentStepController.reorder(new List<Id>{ a, b });
            Assert.fail('Different work items');
        } catch (AuraHandledException e) {
            assertFails('different work items', e.getMessage());
        }
        delete new CDO_Deployment_Step__c(Id = b);
        try {
            DeploymentStepController.reorder(new List<Id>{ a, b });
            Assert.fail('Missing step');
        } catch (AuraHandledException e) {
            assertFails('no longer exist', e.getMessage());
        }
        try {
            DeploymentStepController.completeStep(null);
            Assert.fail('Missing step');
        } catch (AuraHandledException e) {
            assertFails('no longer exists', e.getMessage());
        }
    }

    // ------------------------------------------------------------------------------------------
    // DoraController
    // ------------------------------------------------------------------------------------------

    @IsTest
    static void doraMetricsFromProductionDeploys() {
        CDO_Stage__c prod = stage('demo:prod');
        CDO_Work_Item__c inInt = item('Change in INT');
        CDO_Work_Item__c approved = item('Approved change');
        CDO_Release__c rel = new CDO_Release__c(Name = 'R-dora', Project__c = project().Id, Status__c = 'Released');
        insert rel;
        update new CDO_Work_Item__c(Id = approved.Id, Release__c = rel.Id);
        insert new CDO_Commit__c(Name = 'aaa', Work_Item__c = approved.Id, SHA__c = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            Committed_On__c = System.now().addDays(-4));
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = project().Id, Target_Stage__c = prod.Id, Status__c = 'Deployed');
        insert p;
        insert new CDO_Promoted_Work_Item__c(Promotion__c = p.Id, Work_Item__c = inInt.Id, Unique_Key__c = p.Id + ':' + inInt.Id);

        Datetime now = System.now();
        insert new List<CDO_Deployment__c>{
            new CDO_Deployment__c(Stage__c = prod.Id, Environment__c = prod.Environment__c, Status__c = 'Success', Event_Type__c = 'Deploy',
                Promotion__c = p.Id, Completed_On__c = now.addDays(-3)),
            new CDO_Deployment__c(Stage__c = prod.Id, Environment__c = prod.Environment__c, Status__c = 'Failed', Event_Type__c = 'Deploy',
                Completed_On__c = now.addDays(-2)),
            new CDO_Deployment__c(Stage__c = prod.Id, Environment__c = prod.Environment__c, Status__c = 'Success', Event_Type__c = 'QuickDeploy',
                Release__c = rel.Id, Completed_On__c = now.addDays(-1)),
            // Not counted: a validation and a non-production deploy.
            new CDO_Deployment__c(Stage__c = prod.Id, Status__c = 'Success', Event_Type__c = 'Validation', Check_Only__c = true),
            new CDO_Deployment__c(Stage__c = stage('demo:int').Id, Status__c = 'Failed', Event_Type__c = 'Deploy')
        };

        DoraController.Metrics m = DoraController.getMetrics(project().Id, 30);
        Assert.areEqual(3, m.totalDeployments);
        Assert.areEqual(2, m.successfulDeployments);
        Assert.areEqual(1, m.failedDeployments);
        Assert.areEqual(33.3, m.changeFailureRate);
        Assert.areEqual('Low', m.changeFailureLevel);
        Assert.areEqual(0.47, m.deploymentFrequencyPerWeek);
        Assert.areEqual('Medium', m.deploymentFrequencyLevel);
        Assert.areEqual(1, m.mttrSampleSize);
        Assert.areEqual(24.0, m.mttrHours);
        Assert.areEqual(2, m.leadTimeSampleSize, 'One work item through the promotion junction, one through the release');
        Assert.areEqual(60.0, m.leadTimeHours, 'Median of 48 h and 72 h');
        Assert.areEqual('High', m.leadTimeLevel);
        Assert.areEqual(5, m.weeks.size());
        Integer weekly = 0;
        for (DoraController.WeekPoint w : m.weeks) {
            weekly += w.deployments + w.failures;
        }
        Assert.areEqual(3, weekly);

        DoraController.Metrics defaults = DoraController.getMetrics(null, null);
        Assert.areEqual(30, defaults.days);
        Assert.areEqual(365, DoraController.getMetrics(null, 9999).days);
    }

    @IsTest
    static void doraBandsAndEmptyWindow() {
        DoraController.Metrics m = DoraController.getMetrics(project().Id, 7);
        Assert.areEqual(0, m.totalDeployments);
        Assert.isNull(m.changeFailureRate);
        Assert.isNull(m.leadTimeHours);
        Assert.isNull(m.deploymentFrequencyLevel);
        Assert.areEqual(1, m.weeks.size());

        Assert.areEqual('Elite', DoraController.frequencyLevel(10));
        Assert.areEqual('High', DoraController.frequencyLevel(1));
        Assert.areEqual('Low', DoraController.frequencyLevel(0.1));
        Assert.areEqual('Elite', DoraController.leadTimeLevel(2));
        Assert.areEqual('Medium', DoraController.leadTimeLevel(200));
        Assert.areEqual('Low', DoraController.leadTimeLevel(1000));
        Assert.areEqual('Elite', DoraController.failureLevel(0));
        Assert.areEqual('High', DoraController.failureLevel(8));
        Assert.areEqual('Medium', DoraController.failureLevel(12));
        Assert.areEqual('Elite', DoraController.restoreLevel(0.5));
        Assert.areEqual('High', DoraController.restoreLevel(3));
        Assert.areEqual('Low', DoraController.restoreLevel(500));
        Assert.areEqual(2.0, DoraController.median(new List<Decimal>{ 3, 1, 2 }));
    }

    // ------------------------------------------------------------------------------------------
    // GovernanceController
    // ------------------------------------------------------------------------------------------

    @IsTest
    static void contextAuditAndEventTypes() {
        grant(new List<String>{ GovernanceController.PERM_GOVERNANCE_OPS, GovernanceController.PERM_APPROVE_ENTRY });
        GovernanceController.GovernanceContext ctx = GovernanceController.getContext();
        Assert.isTrue(ctx.canRunOps);
        Assert.isTrue(ctx.canApproveEntry);
        Assert.isFalse(ctx.canRunProdRelease);
        Assert.isFalse(ctx.canConfigure);
        Assert.areEqual(3, ctx.pipelineKeys.size());

        CDO_Work_Item__c wi = item('Fresh change');
        CDO_Audit.log('Status', 'One', null, new Map<String, Id>{ 'workItem' => wi.Id });
        CDO_Audit.log('Other', 'Two', null, null);

        Assert.isTrue(GovernanceController.getAuditEvents(null, null, null).size() >= 2);
        Assert.areEqual(1, GovernanceController.getAuditEvents('Status', wi.Id, 5).size());
        Assert.areEqual(1, GovernanceController.getAuditEvents('Other', null, 5000).size());
        Assert.isTrue(GovernanceController.getEventTypes().contains('Status'));
        Assert.isTrue(GovernanceController.getApprovals(null).isEmpty());

        GovernanceController.testPermissions = null;
        Assert.isFalse(GovernanceController.hasPermission('CDO_Not_A_Real_Permission'));
    }

    @IsTest
    static void approvingADraftDispatchesIt() {
        mockGitHub();
        grant(new List<String>());
        PromotionController.PromotionResult draft = PromotionController.promoteWorkItemOnly(item('Approved change').Id);

        List<GovernanceController.PendingPromotion> pending = GovernanceController.getPendingPromotions();
        Assert.areEqual(1, pending.size());
        Assert.isTrue(pending[0].isEntry);
        Assert.isFalse(pending[0].canApprove, 'The entry stage needs CDO_Approve_Entry');
        try {
            GovernanceController.recordApproval(draft.promotionId, 'Approved', null);
            Assert.fail('Needs CDO_Approve_Entry');
        } catch (AuraHandledException e) {
            assertFails(GovernanceController.PERM_APPROVE_ENTRY, e.getMessage());
        }

        grant(new List<String>{ GovernanceController.PERM_APPROVE_ENTRY });
        Test.startTest();
        GovernanceController.ApprovalResult result = GovernanceController.recordApproval(draft.promotionId, 'approve', 'Looks good');
        Test.stopTest();

        Assert.isTrue(result.dispatched);
        Assert.areEqual('Approved', result.decision);
        String status = [SELECT Status__c FROM CDO_Promotion__c WHERE Id = :draft.promotionId].Status__c;
        Assert.isTrue(status == 'Queued' || status == 'Dispatched', status);
        List<CDO_Approval__c> approvals = GovernanceController.getApprovals(draft.promotionId);
        Assert.areEqual(1, approvals.size());
        Assert.areEqual('Manual', approvals[0].Method__c);
        Assert.isNotNull(approvals[0].Work_Item__c);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = 'Approval' AND Promotion__c = :draft.promotionId]);

        try {
            GovernanceController.recordApproval(draft.promotionId, 'Approved', null);
            Assert.fail('Only Drafts wait for a decision');
        } catch (AuraHandledException e) {
            assertFails('Only a Draft', e.getMessage());
        }
    }

    @IsTest
    static void rejectingAndHoldingDrafts() {
        grant(new List<String>());
        CDO_Work_Item__c inInt = item('Change in INT');
        update new CDO_Work_Item__c(Id = inInt.Id, Last_Coverage__c = 70);
        PromotionController.PromotionResult draft = PromotionController.promoteWorkItemOnly(inInt.Id);

        try {
            GovernanceController.recordApproval(draft.promotionId, 'Rejected', ' ');
            Assert.fail('A rejection needs a comment');
        } catch (AuraHandledException e) {
            assertFails('comment', e.getMessage());
        }
        try {
            GovernanceController.recordApproval(draft.promotionId, 'Maybe', 'x');
            Assert.fail('Unknown decision');
        } catch (AuraHandledException e) {
            assertFails('Approved or Rejected', e.getMessage());
        }
        try {
            GovernanceController.recordApproval(null, 'Approved', 'x');
            Assert.fail('Missing promotion');
        } catch (AuraHandledException e) {
            assertFails('Choose a promotion', e.getMessage());
        }

        // inInt has 70% coverage against a 75% minimum: approved, but held back.
        GovernanceController.ApprovalResult held = GovernanceController.recordApproval(draft.promotionId, 'Approved', null);
        Assert.isFalse(held.dispatched);
        assertFails('held', held.message);
        Assert.areEqual('Draft', [SELECT Status__c FROM CDO_Promotion__c WHERE Id = :draft.promotionId].Status__c);
        Assert.isNotNull(GovernanceController.getPendingPromotions()[0].coverageHold);

        GovernanceController.ApprovalResult rejected = GovernanceController.recordApproval(draft.promotionId, 'reject', 'Wrong branch');
        Assert.areEqual('Cancelled', rejected.promotionStatus);
        CDO_Promotion__c p = [SELECT Status__c, Message__c FROM CDO_Promotion__c WHERE Id = :draft.promotionId];
        Assert.areEqual('Cancelled', p.Status__c);
        assertFails('Wrong branch', p.Message__c);
    }

    @IsTest
    static void productionApprovalNeedsProdPermission() {
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = project().Id, Target_Stage__c = stage('demo:prod').Id, Status__c = 'Draft');
        insert p;
        grant(new List<String>());
        try {
            GovernanceController.recordApproval(p.Id, 'Approved', null);
            Assert.fail('Needs CDO_Run_Prod_Release');
        } catch (AuraHandledException e) {
            assertFails(GovernanceController.PERM_RUN_PROD_RELEASE, e.getMessage());
        }
    }

    // ------------------------------------------------------------------------------------------
    // GovernanceOpsController
    // ------------------------------------------------------------------------------------------

    @IsTest
    static void opsNeedThePermission() {
        grant(new List<String>());
        for (Integer i = 0; i < 5; i++) {
            try {
                if (i == 0) {
                    GovernanceOpsController.rollback('int', 'abc1234', 'why');
                } else if (i == 1) {
                    GovernanceOpsController.redeployFeature(item('Change in INT').Id, 'qa');
                } else if (i == 2) {
                    GovernanceOpsController.recreateFeature(item('Change in INT').Id);
                } else if (i == 3) {
                    GovernanceOpsController.syncEnvBranches('');
                } else {
                    GovernanceOpsController.runConflictCheck();
                }
                Assert.fail('Must need CDO_Governance_Ops: ' + i);
            } catch (AuraHandledException e) {
                assertFails(GovernanceController.PERM_GOVERNANCE_OPS, e.getMessage());
            }
        }
    }

    // Each operation is one synchronous callout followed by an audit insert, and a callout cannot
    // follow DML in the same transaction, so each runs in its own test.

    @IsTest
    static void opsRollbackDispatchesAndAudits() {
        grant(new List<String>{ GovernanceController.PERM_GOVERNANCE_OPS });
        Test.startTest();
        mockGitHub();
        assertFails('Rollback of int to abc1234', GovernanceOpsController.rollback('int', 'ABC1234', 'Bad deploy'));
        Test.stopTest();
        CDO_Audit_Event__c ev = [SELECT Summary__c, Details__c FROM CDO_Audit_Event__c WHERE Event_Type__c = 'Rollback'];
        assertFails('Bad deploy', ev.Details__c);
    }

    @IsTest
    static void opsRedeployFeatureDispatchesAndAudits() {
        grant(new List<String>{ GovernanceController.PERM_GOVERNANCE_OPS });
        CDO_Work_Item__c inInt = item('Change in INT');
        Test.startTest();
        mockGitHub();
        assertFails('Redeploy of ' + inInt.Name + ' to qa', GovernanceOpsController.redeployFeature(inInt.Id, 'qa'));
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = 'Redeploy' AND Work_Item__c = :inInt.Id]);
    }

    @IsTest
    static void opsRecreateFeatureDispatchesAndAudits() {
        grant(new List<String>{ GovernanceController.PERM_GOVERNANCE_OPS });
        CDO_Work_Item__c inInt = item('Change in INT');
        Test.startTest();
        mockGitHub();
        assertFails('Recreating feature/' + inInt.Name + ' from 2 paths', GovernanceOpsController.recreateFeature(inInt.Id));
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = 'Recreate Feature' AND Work_Item__c = :inInt.Id]);
    }

    @IsTest
    static void opsSyncAllBranchesDispatchesAndAudits() {
        grant(new List<String>{ GovernanceController.PERM_GOVERNANCE_OPS });
        Test.startTest();
        mockGitHub();
        assertFails('all environment branches', GovernanceOpsController.syncEnvBranches(null));
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = 'Sync']);
    }

    @IsTest
    static void opsSyncOneBranchDispatches() {
        grant(new List<String>{ GovernanceController.PERM_GOVERNANCE_OPS });
        Test.startTest();
        mockGitHub();
        assertFails('the qa branch', GovernanceOpsController.syncEnvBranches('qa'));
        Test.stopTest();
    }

    @IsTest
    static void opsConflictCheckDispatchesAndAudits() {
        grant(new List<String>{ GovernanceController.PERM_GOVERNANCE_OPS });
        Test.startTest();
        mockGitHub();
        assertFails('Conflict check of 2 work items', GovernanceOpsController.runConflictCheck());
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = 'Conflict']);
    }

    @IsTest
    static void opsValidateInputs() {
        grant(new List<String>{ GovernanceController.PERM_GOVERNANCE_OPS });
        Map<Integer, String> expected = new Map<Integer, String>{
            0 => 'commit SHA',
            1 => 'reason',
            2 => 'not a pipeline key',
            3 => 'target environment',
            4 => 'existing work item',
            5 => 'no tracked component paths'
        };
        for (Integer i : expected.keySet()) {
            try {
                if (i == 0) {
                    GovernanceOpsController.rollback('int', 'not-a-sha', 'why');
                } else if (i == 1) {
                    GovernanceOpsController.rollback('int', 'abc1234', ' ');
                } else if (i == 2) {
                    GovernanceOpsController.rollback('nowhere', 'abc1234', 'why');
                } else if (i == 3) {
                    GovernanceOpsController.redeployFeature(item('Change in INT').Id, '');
                } else if (i == 4) {
                    GovernanceOpsController.recreateFeature(null);
                } else {
                    GovernanceOpsController.recreateFeature(item('Fresh change').Id);
                }
                Assert.fail('Must be refused: ' + i);
            } catch (AuraHandledException e) {
                assertFails(expected.get(i), e.getMessage());
            }
        }
        delete [SELECT Id FROM CDO_Component__c WHERE Work_Item__r.Subject__c = 'Approved change'];
        try {
            GovernanceOpsController.runConflictCheck();
            Assert.fail('Needs two work items');
        } catch (AuraHandledException e) {
            assertFails('at least two', e.getMessage());
        }
    }

    @IsTest
    static void opsSurfaceAGitHubRefusal() {
        grant(new List<String>{ GovernanceController.PERM_GOVERNANCE_OPS });
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new GitHubMock(404, 200));
        try {
            GovernanceOpsController.syncEnvBranches('int');
            Assert.fail('A refused dispatch must surface');
        } catch (AuraHandledException e) {
            assertFails('HTTP 404', e.getMessage());
            assertFails('not found', e.getMessage());
        }
        Test.stopTest();
        Assert.areEqual(0, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = 'Sync']);
    }

    // ------------------------------------------------------------------------------------------
    // IntegrationController
    // ------------------------------------------------------------------------------------------

    @IsTest
    static void settingsNeedConfigurePermission() {
        CDO_Settings__c current = IntegrationController.getSettings();
        Assert.areEqual('acme', current.GitHub_Owner__c);

        grant(new List<String>());
        try {
            IntegrationController.saveSettings(current);
            Assert.fail('Needs CDO_Configure_Pipeline');
        } catch (AuraHandledException e) {
            assertFails(GovernanceController.PERM_CONFIGURE_PIPELINE, e.getMessage());
        }

        grant(new List<String>{ GovernanceController.PERM_CONFIGURE_PIPELINE });
        CDO_Settings__c saved = IntegrationController.saveSettings(new CDO_Settings__c(GitHub_Owner__c = ' acme-org ', GitHub_Repo__c = 'repo.v2',
            Workflow_Ref__c = 'main', Named_Credential__c = 'GitHub_API', Dispatch_Enabled__c = false, Promotion_Timeout_Minutes__c = 60));
        Assert.areEqual('acme-org', saved.GitHub_Owner__c);
        Assert.isFalse(saved.Dispatch_Enabled__c);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Settings__c], 'The org default is updated, not duplicated');

        List<CDO_Settings__c> bad = new List<CDO_Settings__c>{
            null,
            new CDO_Settings__c(GitHub_Owner__c = 'bad owner'),
            new CDO_Settings__c(GitHub_Repo__c = 'acme/repo'),
            new CDO_Settings__c(Named_Credential__c = 'has-dash'),
            new CDO_Settings__c(Promotion_Timeout_Minutes__c = 0)
        };
        for (CDO_Settings__c s : bad) {
            try {
                IntegrationController.saveSettings(s);
                Assert.fail('Must be refused: ' + s);
            } catch (AuraHandledException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
    }

    @IsTest
    static void webhooks() {
        grant(new List<String>{ GovernanceController.PERM_CONFIGURE_PIPELINE });
        Id hookId = IntegrationController.saveWebhook(new CDO_Webhook__c(Name = 'Team space', Named_Credential__c = 'Webex_API',
            Path__c = 'v1/messages', Events__c = 'Deploy;Release', Active__c = true));
        CDO_Webhook__c hook = IntegrationController.getWebhooks()[0];
        Assert.areEqual(hookId, hook.Id);
        Assert.areEqual('/v1/messages', hook.Path__c);
        Assert.areEqual('Generic_JSON', hook.Format__c);

        List<CDO_Webhook__c> bad = new List<CDO_Webhook__c>{
            null,
            new CDO_Webhook__c(Named_Credential__c = 'X'),
            new CDO_Webhook__c(Name = 'No credential'),
            new CDO_Webhook__c(Name = 'Bad credential', Named_Credential__c = 'not valid')
        };
        for (CDO_Webhook__c w : bad) {
            try {
                IntegrationController.saveWebhook(w);
                Assert.fail('Must be refused: ' + w);
            } catch (AuraHandledException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
        grant(new List<String>());
        try {
            IntegrationController.saveWebhook(hook);
            Assert.fail('Needs CDO_Configure_Pipeline');
        } catch (AuraHandledException e) {
            assertFails(GovernanceController.PERM_CONFIGURE_PIPELINE, e.getMessage());
        }
    }

    @IsTest
    static void connectionTestAndHealth() {
        insert new CDO_Audit_Event__c(Event_Type__c = 'Deploy', Summary__c = 'Callback from GitHub', Source__c = 'GitHub',
            Occurred_On__c = System.now().addMinutes(-5));

        Test.startTest();
        mockGitHub();
        IntegrationController.ConnectionResult ok = IntegrationController.testGitHubConnection();
        IntegrationController.Health h = IntegrationController.getHealth();
        Test.stopTest();

        Assert.isTrue(ok.ok, ok.message);
        Assert.areEqual(200, ok.statusCode);
        Assert.areEqual('https://github.com/acme/sf-repo', ok.repoUrl);
        Assert.isTrue(h.settingsComplete);
        Assert.isTrue(h.dispatchEnabled);
        Assert.isTrue(h.namedCredentialReachable);
        Assert.isTrue(h.healthy);
        Assert.areEqual('GitHub_API', h.namedCredential);
        Assert.areEqual('Callback from GitHub', h.lastCallbackSummary);
        Assert.isNotNull(h.lastCallbackOn);
    }

    @IsTest
    static void connectionFailuresAreExplained() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new GitHubMock(204, 404));
        IntegrationController.ConnectionResult notFound = IntegrationController.testGitHubConnection();
        Test.stopTest();
        Assert.isFalse(notFound.ok);
        assertFails('404', notFound.message);
    }

    @IsTest
    static void connectionAndDispatchErrorsCarryAHint() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new GitHubMock(401, 401));
        assertFails('refused the token', IntegrationController.testGitHubConnection().message);
        try {
            IntegrationController.dispatchOrFail(GitHubService.WF_SYNC_ENV, new Map<String, String>());
            Assert.fail('401 must fail');
        } catch (AuraHandledException e) {
            assertFails('bootstrap-secrets.sh', e.getMessage());
        }

        Test.setMock(HttpCalloutMock.class, new GitHubMock(422, 500));
        assertFails('HTTP 500', IntegrationController.testGitHubConnection().message);
        try {
            IntegrationController.dispatchOrFail(GitHubService.WF_SYNC_ENV, new Map<String, String>());
            Assert.fail('422 must fail');
        } catch (AuraHandledException e) {
            assertFails('rejected the inputs', e.getMessage());
        }

        Test.setMock(HttpCalloutMock.class, new GitHubMock(500, 200));
        try {
            IntegrationController.dispatchOrFail(GitHubService.WF_SYNC_ENV, new Map<String, String>());
            Assert.fail('500 must fail');
        } catch (AuraHandledException e) {
            assertFails('Try again', e.getMessage());
        }

        Test.setMock(HttpCalloutMock.class, new PlainTextMock());
        assertFails('Service Unavailable', IntegrationController.testGitHubConnection().message);

        Test.setMock(HttpCalloutMock.class, new UnreachableMock());
        IntegrationController.ConnectionResult unreachable = IntegrationController.testGitHubConnection();
        Assert.areEqual(0, unreachable.statusCode);
        assertFails('Named Credential exists', unreachable.message);
        try {
            IntegrationController.dispatchOrFail(GitHubService.WF_SYNC_ENV, new Map<String, String>());
            Assert.fail('An unreachable GitHub must fail');
        } catch (AuraHandledException e) {
            assertFails('GitHub_API Named Credential', e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void createWorkItemSurfacesDatabaseErrors() {
        try {
            // Story points is Number(3, 0): the database refuses 12345.
            WorkItemController.createWorkItem(new Map<String, Object>{
                'Subject__c' => 'Too many points',
                'Story_Points__c' => 12345
            });
            Assert.fail('The insert must fail');
        } catch (AuraHandledException e) {
            assertFails('Could not create the work item', e.getMessage());
        }
    }

    @IsTest
    static void healthWithoutSettings() {
        delete [SELECT Id FROM CDO_Settings__c];
        IntegrationController.ConnectionResult r = IntegrationController.testGitHubConnection();
        Assert.isFalse(r.ok);
        assertFails('GitHub Owner', r.message);
        IntegrationController.Health h = IntegrationController.getHealth();
        Assert.isFalse(h.settingsComplete);
        Assert.isFalse(h.healthy);
        Assert.areEqual(2, h.missingSettings.size());
        Assert.isNull(h.lastCallbackOn);
        try {
            IntegrationController.dispatchOrFail(GitHubService.WF_SYNC_ENV, new Map<String, String>());
            Assert.fail('Unconfigured dispatch must fail');
        } catch (AuraHandledException e) {
            assertFails('not configured', e.getMessage());
        }
    }
}
