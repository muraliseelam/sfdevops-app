@isTest
private class CDOWorkItemCommandCenterTest {

    @testSetup
    static void setup() {
        new CDO_Tests.TestData();
    }

    private static void readyAt(CDO_Work_Item__c wi, CDO_Stage__c stage) {
        update new CDO_Work_Item__c(
            Id = wi.Id,
            Current_Stage__c = stage == null ? null : stage.Id,
            Status__c = 'Deployed',
            Last_Commit_SHA__c = 'abc1234',
            Pull_Request_Number__c = 7,
            Pull_Request_URL__c = 'https://github.com/acme/sfdevops-sample/pull/7',
            Pull_Requests_Approved__c = true
        );
    }

    private static String refusal(Id workItemId, String action, String paramsJson) {
        try {
            CDOWorkItemCommandCenter.performAction(workItemId, action, paramsJson);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        Assert.fail(action + ' should have been refused');
        return null;
    }

    @isTest
    static void aFreshWorkItemCanOnlyCommit() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDOWorkItemCommandCenter.State st = CDOWorkItemCommandCenter.getState(d.workItems[0].Id);
        Assert.areEqual(d.workItems[0].Id, st.workItem.Id);
        Assert.areEqual(4, st.path.size());
        Assert.areEqual('INT', st.path[0].name);
        Assert.areEqual('PROD', st.path[3].name);
        Assert.isTrue(st.path[0].isEntry);
        Assert.isTrue(st.path[3].isProduction);
        for (CDOWorkItemCommandCenter.StageStep step : st.path) {
            Assert.isFalse(step.isCurrent, 'no stage yet');
            Assert.isFalse(step.isCompleted);
        }
        Assert.isTrue(st.path[0].isNext);
        Assert.areEqual('INT', st.nextStageName);
        Assert.isNull(st.currentStageId);
        Assert.isTrue(st.dispatchEnabled);
        Assert.areEqual('https://github.com/acme/sfdevops-sample', st.repoUrl);
        Assert.areEqual('feature/' + d.workItems[0].Name, st.featureBranch);
        Assert.isTrue(st.availableActions.get('commit'));
        Assert.isFalse(st.availableActions.get('openPr'));
        Assert.isFalse(st.availableActions.get('validate'));
        Assert.isFalse(st.availableActions.get('promote'));
        Assert.isFalse(st.availableActions.get('promoteAndDeploy'));
        Assert.isTrue(st.actionReasons.get('openPr').contains('Commit changes'));
        Assert.isTrue(st.actionReasons.get('validate').contains('pull request'));
        Assert.isTrue(st.actionReasons.get('promote').contains('Commit changes'));
        Assert.areEqual(0, st.commits.size());
        Assert.areEqual(0, st.deployments.size());
        Assert.areEqual(0, st.promotions.size());
    }

    @isTest
    static void stateShowsTheLatestHistoryInOrder() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        readyAt(wi, d.stageInt);
        List<CDO_Commit__c> commits = new List<CDO_Commit__c>();
        List<CDO_Deployment__c> deployments = new List<CDO_Deployment__c>();
        for (Integer i = 0; i < 12; i++) {
            String sha = String.valueOf(i).leftPad(40, 'a');
            commits.add(new CDO_Commit__c(Name = 'c' + i, Work_Item__c = wi.Id, SHA__c = sha));
            deployments.add(new CDO_Deployment__c(Work_Item__c = wi.Id, Stage__c = d.stageInt.Id, Status__c = 'Success', Message__c = 'd' + i));
        }
        insert commits;
        insert deployments;
        Datetime base = System.now().addDays(-1);
        for (Integer i = 0; i < 12; i++) {
            Test.setCreatedDate(deployments[i].Id, base.addMinutes(i));
        }
        // Two rows in the same second: the tie is broken by Id, never left to chance.
        Test.setCreatedDate(deployments[10].Id, base.addMinutes(11));
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageInt.Id, Status__c = 'Deployed');
        insert p;
        insert CDOPromotionDispatcher.junctionRows(p.Id, new List<CDO_Work_Item__c>{ wi });
        insert new CDO_Approval__c(Work_Item__c = wi.Id, Stage__c = d.stageInt.Id, Decision__c = 'Approved', Approver__c = 'octocat');
        insert new CDO_Component__c(Name = 'ApexClass:Foo', Work_Item__c = wi.Id, Metadata_Type__c = 'ApexClass', Member_Name__c = 'Foo', Work_Item_Key__c = wi.Name + '|ApexClass:Foo');

        CDOWorkItemCommandCenter.State st = CDOWorkItemCommandCenter.getState(wi.Id);
        Assert.areEqual(10, st.commits.size(), 'the last 10 commits');
        Assert.areEqual(10, st.deployments.size(), 'the last 10 deployments');
        // deployments[11] was inserted after deployments[10], so it has the higher Id.
        Assert.areEqual(deployments[11].Id, st.deployments[0].Id, 'CreatedDate DESC, then Id DESC');
        Assert.areEqual(deployments[10].Id, st.deployments[1].Id);
        Assert.areEqual(deployments[9].Id, st.deployments[2].Id);
        Assert.areEqual(1, st.components.size());
        Assert.areEqual(1, st.approvals.size());
        Assert.areEqual(1, st.promotions.size());
        Assert.areEqual(p.Id, st.promotions[0].promotionId);
        Assert.areEqual('Pending', st.promotions[0].itemStatus);
        Assert.areEqual('INT', st.promotions[0].targetStageName);
        Assert.isNull(st.openPromotionId);
        Assert.isTrue(st.path[0].isCurrent);
        Assert.isTrue(st.path[1].isNext);
        Assert.areEqual('QA', st.nextStageName);
        Assert.isFalse(st.availableActions.get('openPr'), 'a pull request is already open');
        Assert.isTrue(st.availableActions.get('validate'));
        Assert.isTrue(st.availableActions.get('promote'));
        Assert.isTrue(st.availableActions.get('promoteAndDeploy'));
        Assert.isTrue(st.availableActions.get('commit'));

        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = d.stageQa.Id);
        CDOWorkItemCommandCenter.State later = CDOWorkItemCommandCenter.getState(wi.Id);
        Assert.isTrue(later.path[0].isCompleted);
        Assert.isTrue(later.path[1].isCurrent);
    }

    @isTest
    static void promoteMakesADraftAndPromoteAndDeployQueuesIt() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Work_Item__c a = d.workItems[0];
        CDO_Work_Item__c b = d.workItems[1];
        readyAt(a, d.stageInt);
        readyAt(b, d.stageInt);
        Test.setMock(HttpCalloutMock.class, new CDO_Tests.GitHubMock());

        CDOWorkItemCommandCenter.ActionResult draft = CDOWorkItemCommandCenter.performAction(a.Id, 'promote', null);
        Assert.isTrue(draft.success);
        CDO_Promotion__c p = CDO_Tests.promotion(draft.recordId);
        Assert.areEqual('Draft', p.Status__c);
        Assert.areEqual(d.stageQa.Id, p.Target_Stage__c);
        Assert.areEqual(1, p.Promoted_Work_Items__r.size(), 'the promote action writes the junction row');
        CDOWorkItemCommandCenter.State st = CDOWorkItemCommandCenter.getState(a.Id);
        Assert.areEqual(p.Id, st.openPromotionId);
        Assert.isFalse(st.availableActions.get('promote'));
        Assert.isTrue(st.actionReasons.get('promoteAndDeploy').contains('Draft'));
        Assert.isTrue(refusal(a.Id, 'promoteAndDeploy', null).contains('Draft'));

        CDOWorkItemCommandCenter.ActionResult queued = CDOWorkItemCommandCenter.performAction(a.Id, 'dispatchPromotion', null);
        Assert.areEqual(p.Id, queued.recordId);
        Assert.areEqual('Dispatched', CDO_Tests.promotion(p.Id).Status__c);

        CDOWorkItemCommandCenter.ActionResult deploy = CDOWorkItemCommandCenter.performAction(
            b.Id,
            'promoteAndDeploy',
            '{"testLevel":"RunLocalTests","checkOnly":false,"specifiedTests":"FooTest"}'
        );
        CDO_Promotion__c second = CDO_Tests.promotion(deploy.recordId);
        Assert.areEqual('Queued', second.Status__c, 'QA already has a promotion in flight');
        Assert.areEqual('RunLocalTests', second.Test_Level__c);
        Assert.areEqual('FooTest', second.Specified_Tests__c);
        Assert.areEqual(1, second.Promoted_Work_Items__r.size());
        CDOWorkItemCommandCenter.ActionResult again = CDOWorkItemCommandCenter.performAction(
            b.Id, 'dispatchPromotion', JSON.serialize(new Map<String, Object>{ 'promotionId' => second.Id })
        );
        Assert.areEqual('Queued', CDO_Tests.promotion(again.recordId).Status__c);
        Assert.isTrue(refusal(d.workItems[2].Id, 'dispatchPromotion', null).contains('no open promotion'));
    }

    @isTest
    static void dispatchingActionsDelegateToTheServices() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Work_Item__c fresh = d.workItems[0];
        CDO_Work_Item__c committed = d.workItems[1];
        CDO_Work_Item__c reviewed = d.workItems[2];
        update new List<CDO_Work_Item__c>{
            new CDO_Work_Item__c(Id = committed.Id, Last_Commit_SHA__c = 'abc1234', Status__c = 'Committed'),
            new CDO_Work_Item__c(Id = reviewed.Id, Last_Commit_SHA__c = 'abc1234', Pull_Request_Number__c = 9, Status__c = 'In_Review')
        };
        Test.setMock(HttpCalloutMock.class, new CDO_Tests.GitHubMock());
        Test.startTest();
        CDOWorkItemCommandCenter.ActionResult commitResult = CDOWorkItemCommandCenter.performAction(
            fresh.Id, 'commit', '{"components":[{"type":"ApexClass","name":"Foo"}],"message":"Add Foo"}'
        );
        Assert.isTrue(commitResult.success);
        CDOWorkItemCommandCenter.performAction(fresh.Id, 'commit', '{"componentsJson":"[{\\"type\\":\\"ApexClass\\",\\"name\\":\\"Bar\\"}]"}');
        CDOWorkItemCommandCenter.ActionResult listed = CDOWorkItemCommandCenter.performAction(fresh.Id, 'listChanges', '{"sourceOrg":"dev"}');
        Assert.isNotNull(listed.requestId);
        CDOWorkItemCommandCenter.performAction(committed.Id, 'openPr', '');
        CDOWorkItemCommandCenter.performAction(reviewed.Id, 'validate', null);
        Test.stopTest();
        Assert.areEqual(5, CDO_Tests.auditCount('WorkflowDispatched'));
        Assert.areEqual(2, CDO_Tests.auditCount('CommitRequested'));
        Assert.areEqual(1, CDO_Tests.auditCount('PullRequestRequested'));
        Assert.areEqual(1, CDO_Tests.auditCount('ValidationRequested'));
        Assert.areEqual('Requested', CDO_Tests.workItem(fresh.Id).Source_Changes_Status__c);
    }

    @isTest
    static void unavailableOrUnknownActionsAreRefusedWithAReason() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        Assert.isTrue(refusal(wi.Id, 'validate', null).contains('pull request'));
        Assert.isTrue(refusal(wi.Id, 'openPr', null).contains('Commit changes'));
        Assert.isTrue(refusal(wi.Id, 'explode', null).contains('Unknown action'));
        Assert.isTrue(refusal(wi.Id, null, null).contains('Unknown action'));
        Assert.isTrue(refusal(wi.Id, 'commit', '[1]').contains('JSON object'));
        Assert.isTrue(refusal(wi.Id, 'commit', '{oops').contains('valid JSON'));
        Assert.isTrue(refusal(wi.Id, 'commit', '{"components":[]}').contains('component'));
        Assert.isTrue(refusal(null, 'commit', null).contains('required'));
        try {
            CDOWorkItemCommandCenter.getState(null);
            Assert.fail('an id is required');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('required'));
        }
        try {
            CDOWorkItemCommandCenter.getState(CDO_Tests.fakeId(CDO_Work_Item__c.SObjectType));
            Assert.fail('not found');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not found'));
        }

        // The entry stage needs an approved pull request.
        update new CDO_Work_Item__c(Id = wi.Id, Last_Commit_SHA__c = 'abc1234');
        Assert.isTrue(refusal(wi.Id, 'promote', null).contains('approved'));
        // Coverage below the work item's minimum holds the promotion back.
        update new CDO_Work_Item__c(Id = wi.Id, Pull_Requests_Approved__c = true, Minimum_Coverage__c = 85, Last_Coverage__c = 70);
        Assert.isTrue(refusal(wi.Id, 'promoteAndDeploy', null).contains('below the minimum'));
        // Production ships through a release.
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = d.stageStage.Id, Last_Coverage__c = 90);
        Assert.isTrue(refusal(wi.Id, 'promote', null).contains('release'));
        // Nothing comes after production.
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = d.stageProd.Id);
        Assert.isTrue(refusal(wi.Id, 'promote', null).contains('last stage'));
        // A closed work item does nothing.
        update new CDO_Work_Item__c(Id = wi.Id, Status__c = 'Done');
        CDOWorkItemCommandCenter.State closed = CDOWorkItemCommandCenter.getState(wi.Id);
        for (String action : CDOWorkItemCommandCenter.ACTIONS) {
            Assert.isFalse(closed.availableActions.get(action), action);
        }
        // A work item without a project has no next stage.
        CDO_Work_Item__c orphan = d.workItems[1];
        update new CDO_Work_Item__c(Id = orphan.Id, Project__c = null, Last_Commit_SHA__c = 'abc1234');
        Assert.isTrue(refusal(orphan.Id, 'promote', null).contains('no project'));
    }

    @isTest
    static void dispatchingActionsAreDisabledWhileDispatchIsOff() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        readyAt(wi, d.stageInt);
        update new CDO_Work_Item__c(Id = wi.Id, Pull_Request_Number__c = null, Pull_Request_URL__c = null);
        CDO_Settings__c s = CDO_Settings__c.getOrgDefaults();
        s.Dispatch_Enabled__c = false;
        update s;
        CDOWorkItemCommandCenter.State st = CDOWorkItemCommandCenter.getState(wi.Id);
        Assert.isFalse(st.dispatchEnabled);
        Assert.isFalse(st.availableActions.get('commit'));
        Assert.isFalse(st.availableActions.get('openPr'));
        Assert.isFalse(st.availableActions.get('promoteAndDeploy'));
        Assert.isTrue(st.availableActions.get('promote'), 'a Draft promotion needs no dispatch');
        Assert.isTrue(st.actionReasons.get('commit').contains('Dispatch Enabled'));
        update new CDO_Work_Item__c(Id = wi.Id, Pull_Request_Number__c = 3, Last_Validation_Status__c = 'Running');
        Assert.isTrue(CDOWorkItemCommandCenter.getState(wi.Id).actionReasons.get('validate').contains('already running'));
        update new CDO_Work_Item__c(Id = wi.Id, Last_Validation_Status__c = 'Passed');
        Assert.isTrue(CDOWorkItemCommandCenter.getState(wi.Id).actionReasons.get('validate').contains('Dispatch Enabled'));
    }
}
