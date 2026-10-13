@isTest
private class CDO_PromotionReconcilerTest {

    @testSetup
    static void setup() {
        new CDO_Tests.TestData();
    }

    /** A promotion dispatched two hours ago (older than the 90-minute timeout), with its junction row. */
    private static CDO_Promotion__c stuck(CDO_Tests.TestData d, CDO_Work_Item__c wi, CDO_Stage__c target, String status, String runUrl) {
        CDO_Promotion__c p = new CDO_Promotion__c(
            Project__c = d.project.Id,
            Target_Stage__c = target.Id,
            Status__c = status,
            Direction__c = 'Forward',
            Workflow_Run_URL__c = runUrl,
            Dispatched_On__c = System.now().addMinutes(-120)
        );
        insert p;
        insert CDOPromotionDispatcher.junctionRows(p.Id, new List<CDO_Work_Item__c>{ wi });
        return [SELECT Id, Name, Status__c FROM CDO_Promotion__c WHERE Id = :p.Id];
    }

    private static void sweep(CDO_Tests.GitHubMock mock) {
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        Id jobId = CDO_PromotionReconciler.sweepNow();
        Test.stopTest();
        Assert.isNotNull(jobId, 'the sweep was queued');
    }

    @isTest
    static void neverStartedRunIsMarkedFailed() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = d.stageInt.Id, Status__c = 'Deployed');
        CDO_Promotion__c p = stuck(d, wi, d.stageQa, 'Dispatched', null);
        CDO_Promotion__c queued = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageQa.Id, Status__c = 'Queued');
        insert queued;
        insert CDOPromotionDispatcher.junctionRows(queued.Id, new List<CDO_Work_Item__c>{ d.workItems[1] });

        CDO_Tests.GitHubMock mock = new CDO_Tests.GitHubMock();
        mock.runsBody = CDO_Tests.runsJson(new List<Map<String, Object>>{
            CDO_Tests.run(9001L, 'sf-promotion PRM-99999 WI-0099 -> qa', 'completed', 'success')
        });
        sweep(mock);

        CDO_Promotion__c after = CDO_Tests.promotion(p.Id);
        Assert.areEqual('Failed', after.Status__c);
        Assert.areEqual(CDO_PromotionReconciler.NEVER_STARTED_MESSAGE, after.Message__c);
        Assert.areEqual('Workflow never started: no run URL was ever reported', after.Message__c);
        Assert.isNotNull(after.Completed_On__c);
        Assert.areEqual('Failed', after.Promoted_Work_Items__r[0].Status__c);
        CDO_Work_Item__c item = CDO_Tests.workItem(wi.Id);
        Assert.areEqual('Deployed', item.Status__c, 'nothing ran, so the work item is not blocked');
        Assert.areEqual(d.stageInt.Id, item.Current_Stage__c);
        Assert.isNull(CDO_Tests.environment(d.envQa.Id).Health_Status__c, 'nothing was deployed, so health stays blank');
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = 'PromotionNeverStarted' AND Source__c = 'System' AND Promotion__c = :p.Id]);
        // The stage is free again: the queue tried to dispatch the next promotion. A test cannot chain
        // a queueable from inside one, so the attempt is recorded and the promotion waits, still Queued.
        Assert.areEqual('Queued', CDO_Tests.promotion(queued.Id).Status__c);
        Assert.isTrue([SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = 'PromotionDispatchDeferred' AND Promotion__c = :queued.Id] >= 1);
    }

    @isTest
    static void concludedSuccessfulRunAppliesItsOutcome() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = d.stageInt.Id, Status__c = 'Deployed');
        String runUrl = 'https://github.com/acme/sfdevops-sample/actions/runs/111';
        CDO_Promotion__c p = stuck(d, wi, d.stageQa, 'Deploying', runUrl);
        insert new CDO_Deployment__c(Promotion__c = p.Id, Work_Item__c = wi.Id, Stage__c = d.stageQa.Id, Environment__c = d.envQa.Id, Status__c = 'Running', Workflow_Run_URL__c = runUrl, Event_Type__c = 'Deploy');

        CDO_Tests.GitHubMock mock = new CDO_Tests.GitHubMock();
        mock.runsBody = CDO_Tests.runsJson(new List<Map<String, Object>>{
            CDO_Tests.run(112L, 'another run', 'in_progress', null),
            CDO_Tests.run(111L, 'sf-promotion WI-0001 -> qa', 'completed', 'success')
        });
        sweep(mock);

        Assert.areEqual('Deployed', CDO_Tests.promotion(p.Id).Status__c);
        CDO_Work_Item__c moved = CDO_Tests.workItem(wi.Id);
        Assert.areEqual(d.stageQa.Id, moved.Current_Stage__c);
        Assert.areEqual('Deployed', moved.Status__c);
        List<CDO_Deployment__c> deps = [SELECT Status__c FROM CDO_Deployment__c WHERE Promotion__c = :p.Id];
        Assert.areEqual(1, deps.size(), 'the reconciler finishes the existing row');
        Assert.areEqual('Success', deps[0].Status__c);
        Assert.areEqual('Healthy', CDO_Tests.environment(d.envQa.Id).Health_Status__c);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = 'Callback.Deploy.Success' AND Source__c = 'System']);
    }

    @isTest
    static void concludedFailedRunIsMatchedByThePromotionName() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = d.stageInt.Id, Status__c = 'Deployed');
        CDO_Promotion__c p = stuck(d, wi, d.stageQa, 'Dispatched', null);

        CDO_Tests.GitHubMock mock = new CDO_Tests.GitHubMock();
        mock.runsBody = CDO_Tests.runsJson(new List<Map<String, Object>>{
            CDO_Tests.run(222L, 'sf-promotion ' + p.Name + '0 elsewhere', 'completed', 'success'),
            CDO_Tests.run(223L, 'sf-promotion ' + p.Name + ' ' + wi.Name + ' -> qa', 'completed', 'failure')
        });
        sweep(mock);

        CDO_Promotion__c after = CDO_Tests.promotion(p.Id);
        Assert.areEqual('Failed', after.Status__c, 'PRM-x0 is a different promotion; the run named PRM-x is this one');
        Assert.areEqual('https://github.com/acme/sfdevops-sample/actions/runs/223', after.Workflow_Run_URL__c);
        Assert.isTrue(after.Message__c.contains('never reached the hub'));
        Assert.areEqual('Blocked', CDO_Tests.workItem(wi.Id).Status__c);
        Assert.areEqual('Degraded', CDO_Tests.environment(d.envQa.Id).Health_Status__c);
    }

    @isTest
    static void runStillInProgressIsLeftAlone() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Promotion__c p = stuck(d, d.workItems[0], d.stageQa, 'Dispatched', null);
        CDO_Tests.GitHubMock mock = new CDO_Tests.GitHubMock();
        mock.runsBody = CDO_Tests.runsJson(new List<Map<String, Object>>{
            CDO_Tests.run(333L, 'run for ' + String.valueOf(p.Id), 'in_progress', null)
        });
        sweep(mock);
        Assert.areEqual('Dispatched', CDO_Tests.promotion(p.Id).Status__c);
        Assert.areEqual(1, CDO_Tests.auditCount('ReconcileStillRunning'));
    }

    @isTest
    static void knownRunOutsideTheFirstPageIsFetchedById() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = d.stageInt.Id, Status__c = 'Deployed');
        CDO_Promotion__c p = stuck(d, wi, d.stageQa, 'Deploying', 'https://github.com/acme/sfdevops-sample/actions/runs/444');
        CDO_Tests.GitHubMock mock = new CDO_Tests.GitHubMock();
        mock.runBody = JSON.serialize(CDO_Tests.run(444L, 'old run', 'completed', 'cancelled'));
        sweep(mock);
        Assert.areEqual('Cancelled', CDO_Tests.promotion(p.Id).Status__c);
        Assert.areEqual('Deployed', CDO_Tests.workItem(wi.Id).Status__c);
    }

    @isTest
    static void knownRunThatCannotBeFoundIsNotCalledNeverStarted() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Promotion__c p = stuck(d, d.workItems[0], d.stageQa, 'Deploying', 'https://github.com/acme/sfdevops-sample/actions/runs/555');
        CDO_Tests.GitHubMock mock = new CDO_Tests.GitHubMock();
        mock.runStatus = 404;
        sweep(mock);
        Assert.areEqual('Deploying', CDO_Tests.promotion(p.Id).Status__c, 'it reported a run URL, so it did start');
        Assert.areEqual(1, CDO_Tests.auditCount('ReconcileRunNotFound'));
    }

    @isTest
    static void gitHubErrorLeavesPromotionsUntouched() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Promotion__c p = stuck(d, d.workItems[0], d.stageQa, 'Dispatched', null);
        CDO_Tests.GitHubMock mock = new CDO_Tests.GitHubMock();
        mock.runsStatus = 500;
        mock.runsBody = '{"message":"Server Error"}';
        sweep(mock);
        Assert.areEqual('Dispatched', CDO_Tests.promotion(p.Id).Status__c, 'an unreachable GitHub is not evidence that a run never started');
        Assert.areEqual(1, CDO_Tests.auditCount('ReconcileFailed'));
    }

    @isTest
    static void recentPromotionsAreNotSwept() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageQa.Id, Status__c = 'Dispatched', Dispatched_On__c = System.now());
        insert p;
        insert CDOPromotionDispatcher.junctionRows(p.Id, new List<CDO_Work_Item__c>{ d.workItems[0] });
        sweep(new CDO_Tests.GitHubMock());
        Assert.areEqual('Dispatched', CDO_Tests.promotion(p.Id).Status__c);
        Assert.areEqual(0, CDO_Tests.auditCount('ReconcileFailed'));
        Assert.areEqual(0, CDO_Tests.auditCount('PromotionNeverStarted'));
    }

    @isTest
    static void undispatchedPromotionsUseTheirCreatedDate() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageInt.Id, Status__c = 'Deploying');
        insert p;
        insert CDOPromotionDispatcher.junctionRows(p.Id, new List<CDO_Work_Item__c>{ d.workItems[0] });
        Test.setCreatedDate(p.Id, System.now().addHours(-3));
        CDO_Settings__c s = CDO_Settings__c.getOrgDefaults();
        s.Promotion_Timeout_Minutes__c = null;
        update s;
        sweep(new CDO_Tests.GitHubMock());
        Assert.areEqual('Failed', CDO_Tests.promotion(p.Id).Status__c);
        Assert.areEqual(CDO_PromotionReconciler.DEFAULT_TIMEOUT_MINUTES, CDO_PromotionReconciler.timeoutMinutes());
    }

    @isTest
    static void idleQueuesAreNudged() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Promotion__c queued = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageQa.Id, Status__c = 'Queued');
        insert queued;
        insert CDOPromotionDispatcher.junctionRows(queued.Id, new List<CDO_Work_Item__c>{ d.workItems[0] });
        sweep(new CDO_Tests.GitHubMock());
        // Inside the test the chained dispatch job cannot be queued, so the promotion is put back.
        Assert.areEqual('Queued', CDO_Tests.promotion(queued.Id).Status__c);
        Assert.areEqual(1, CDO_Tests.auditCount('PromotionDispatchDeferred'));
    }

    @isTest
    static void theSchedulableHandsOverToAQueueable() {
        CDO_Tests.loadData();
        Test.setMock(HttpCalloutMock.class, new CDO_Tests.GitHubMock());
        Test.startTest();
        String jobId = System.schedule('CDO reconciler test', '0 0 0 * * ?', new CDO_PromotionReconciler.ReconcileJob());
        Test.stopTest();
        Assert.isNotNull(jobId);
        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = 'CDO reconciler test']);
    }

    @isTest
    static void resolveMovesEveryJunctionWorkItem() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Work_Item__c a = d.workItems[0];
        CDO_Work_Item__c b = d.workItems[1];
        CDO_Work_Item__c cancelled = d.workItems[2];
        update new List<CDO_Work_Item__c>{
            new CDO_Work_Item__c(Id = a.Id, Current_Stage__c = d.stageStage.Id, Status__c = 'Blocked', Blocked_Reason__c = 'old'),
            new CDO_Work_Item__c(Id = b.Id, Current_Stage__c = d.stageStage.Id),
            new CDO_Work_Item__c(Id = cancelled.Id, Status__c = 'Cancelled')
        };
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageProd.Id, Status__c = 'Deployed');
        insert p;
        insert CDOPromotionDispatcher.junctionRows(p.Id, new List<CDO_Work_Item__c>{ a, b, cancelled });
        CDO_PromotionReconciler.resolvePromotedWorkItems(p.Id);
        for (Id i : new List<Id>{ a.Id, b.Id }) {
            CDO_Work_Item__c wi = CDO_Tests.workItem(i);
            Assert.areEqual(d.stageProd.Id, wi.Current_Stage__c);
            Assert.areEqual('Done', wi.Status__c, 'Done at production');
            Assert.areEqual('Merged', wi.Merge_State__c);
            Assert.isNull(wi.Blocked_Reason__c);
        }
        Assert.areEqual('Cancelled', CDO_Tests.workItem(cancelled.Id).Status__c);
        Assert.areEqual(3, [SELECT COUNT() FROM CDO_Promoted_Work_Item__c WHERE Promotion__c = :p.Id AND Status__c = 'Deployed']);
        Assert.areEqual(1, CDO_Tests.auditCount('PromotionResolved'));
        CDO_PromotionReconciler.resolvePromotedWorkItems(null);
        CDO_PromotionReconciler.resolvePromotedWorkItems(CDO_Tests.fakeId(CDO_Promotion__c.SObjectType));
    }

    @isTest
    static void resolveWithoutJunctionRowsReturnsEarlyAndSaysSo() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageQa.Id, Status__c = 'Deployed');
        insert p;
        CDO_PromotionReconciler.resolvePromotedWorkItems(p.Id);
        CDO_Audit_Event__c ev = [SELECT Summary__c, Promotion__c FROM CDO_Audit_Event__c WHERE Event_Type__c = 'PromotionUnresolved'];
        Assert.areEqual(p.Id, ev.Promotion__c);
        Assert.isTrue(ev.Summary__c.contains('no promoted work items'));
        Assert.areEqual(0, [SELECT COUNT() FROM CDO_Work_Item__c WHERE Current_Stage__c = :d.stageQa.Id]);
    }

    @isTest
    static void aLateResultNeverDragsAWorkItemBack() {
        CDO_Tests.TestData d = CDO_Tests.loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = d.stageStage.Id, Status__c = 'Deployed');
        CDO_Promotion__c late = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageQa.Id, Status__c = 'Deployed', Direction__c = 'Forward');
        CDO_Promotion__c back = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageInt.Id, Status__c = 'Deployed', Direction__c = 'Back');
        insert new List<CDO_Promotion__c>{ late, back };
        insert CDOPromotionDispatcher.junctionRows(late.Id, new List<CDO_Work_Item__c>{ wi });
        CDO_PromotionReconciler.resolvePromotedWorkItems(late.Id);
        Assert.areEqual(d.stageStage.Id, CDO_Tests.workItem(wi.Id).Current_Stage__c);
        insert CDOPromotionDispatcher.junctionRows(back.Id, new List<CDO_Work_Item__c>{ wi });
        CDO_PromotionReconciler.resolvePromotedWorkItems(back.Id);
        Assert.areEqual(d.stageInt.Id, CDO_Tests.workItem(wi.Id).Current_Stage__c, 'a Back promotion moves it down on purpose');
    }

    @isTest
    static void helpersMatchRunsPrecisely() {
        Assert.isTrue(CDO_PromotionReconciler.containsToken('sf-promotion PRM-00001 -> qa', 'PRM-00001'));
        Assert.isFalse(CDO_PromotionReconciler.containsToken('sf-promotion PRM-000012 -> qa', 'PRM-00001'));
        Assert.isTrue(CDO_PromotionReconciler.containsToken('PRM-000012 then PRM-00001', 'PRM-00001'));
        Assert.isTrue(CDO_PromotionReconciler.containsToken('ends with PRM-00001', 'PRM-00001'));
        Assert.isFalse(CDO_PromotionReconciler.containsToken(null, 'PRM-00001'));
        Assert.areEqual('Success', CDO_PromotionReconciler.outcome('success'));
        Assert.areEqual('Cancelled', CDO_PromotionReconciler.outcome('cancelled'));
        Assert.areEqual('Failed', CDO_PromotionReconciler.outcome('timed_out'));
        Assert.areEqual('123', CDO_PromotionReconciler.runIdFromUrl('https://github.com/a/b/actions/runs/123/attempts/2'));
        Assert.isNull(CDO_PromotionReconciler.runIdFromUrl('https://github.com/a/b/pull/1'));
        Assert.isNull(CDO_PromotionReconciler.runIdFromUrl('https://github.com/a/b/actions/runs/abc'));
        Assert.areEqual(0, CDO_PromotionReconciler.parseRuns(null).size());
        Assert.areEqual(0, CDO_PromotionReconciler.parseRuns('[]').size());
        Assert.areEqual(0, CDO_PromotionReconciler.parseRuns('{"workflow_runs":"x"}').size());
        Assert.isNull(CDO_PromotionReconciler.parseRun('x'));
        Assert.isNull(CDO_PromotionReconciler.findRun(null, null));
    }
}
