/**
 * Tests for the hub's integration and services layer, plus a reusable data factory and callout mock.
 *
 * Other test classes reuse:
 *   new CDO_Tests.TestData()          creates settings, a project, int/qa/stage + prod stages and
 *                                     environments, and 3 work items (TestData(n) for n items)
 *   CDO_Tests.loadData()              reloads them in a test method after an @testSetup created them
 *   new CDO_Tests.GitHubMock()        HttpCalloutMock: dispatch 204 (or dispatchStatus), workflow runs,
 *                                     repository and webhook responses; every request lands in CDO_Tests.calls
 *   CDO_Tests.postCallback(map) / postMergeStatus(map) / postSourceMembers(map)   call the REST resources
 */
@isTest
public class CDO_Tests {

    public static final String OWNER = 'acme';
    public static final String REPO = 'sfdevops-sample';
    public static final String PROJECT_KEY = 'sample';
    public static final String RUN_URL = 'https://github.com/acme/sfdevops-sample/actions/runs/1001';
    public static final String RUN_URL_2 = 'https://github.com/acme/sfdevops-sample/actions/runs/1002';

    /** Every request the GitHubMock answered in this test (synchronous code only). */
    public static List<HttpRequest> calls = new List<HttpRequest>();

    // ---- Data factory ------------------------------------------------------------------------------

    public class TestData {
        public CDO_Settings__c settings;
        public CDO_Project__c project;
        public CDO_Environment__c envInt;
        public CDO_Environment__c envQa;
        public CDO_Environment__c envStage;
        public CDO_Environment__c envProd;
        public CDO_Stage__c stageInt;
        public CDO_Stage__c stageQa;
        public CDO_Stage__c stageStage;
        public CDO_Stage__c stageProd;
        /** int, qa, stage, prod */
        public List<CDO_Environment__c> environments = new List<CDO_Environment__c>();
        /** int (entry), qa, stage, prod (production), in promotion order */
        public List<CDO_Stage__c> stages = new List<CDO_Stage__c>();
        /** Ordered by Name (WI-0001, WI-0002, ...) */
        public List<CDO_Work_Item__c> workItems = new List<CDO_Work_Item__c>();

        public TestData() {
            this(3);
        }

        /** Creates everything, with workItemCount work items. */
        public TestData(Integer workItemCount) {
            settings = new CDO_Settings__c(
                SetupOwnerId = UserInfo.getOrganizationId(),
                GitHub_Owner__c = OWNER,
                GitHub_Repo__c = REPO,
                Workflow_Ref__c = 'main',
                Named_Credential__c = 'GitHub_API',
                Default_Project_Key__c = PROJECT_KEY,
                Dispatch_Enabled__c = true,
                Promotion_Timeout_Minutes__c = 90
            );
            insert settings;
            project = new CDO_Project__c(
                Name = 'Sample Project',
                Key__c = PROJECT_KEY,
                Repository__c = OWNER + '/' + REPO,
                Baseline_Branch__c = 'main',
                Active__c = true,
                Coverage_Threshold__c = 85
            );
            insert project;
            envInt = newEnvironment('int', 'Pipeline');
            envQa = newEnvironment('qa', 'Pipeline');
            envStage = newEnvironment('stage', 'Pipeline');
            envProd = newEnvironment('prod', 'Production');
            environments = new List<CDO_Environment__c>{ envInt, envQa, envStage, envProd };
            insert environments;
            stageInt = newStage('INT', 'int', 'int', 1, envInt, 'Review');
            stageInt.Is_Entry__c = true;
            stageQa = newStage('QA', 'qa', 'qa', 2, envQa, 'Self_Service');
            stageStage = newStage('STAGE', 'stage', 'stage', 3, envStage, 'Self_Service');
            stageProd = newStage('PROD', 'prod', 'main', 4, envProd, 'Required_Reviewer');
            stageProd.Is_Production__c = true;
            stages = new List<CDO_Stage__c>{ stageInt, stageQa, stageStage, stageProd };
            insert stages;
            List<CDO_Work_Item__c> items = new List<CDO_Work_Item__c>();
            Integer count = workItemCount == null ? 3 : workItemCount;
            for (Integer i = 1; i <= count; i++) {
                items.add(
                    new CDO_Work_Item__c(
                        Subject__c = 'Sample change ' + i,
                        Project__c = project.Id,
                        Status__c = 'New',
                        Source_Org_Alias__c = 'dev'
                    )
                );
            }
            insert items;
            workItems = queryWorkItems(project.Id);
        }

        /** Loads the records an earlier TestData (for example in @testSetup) created for the project key. */
        public TestData(String existingProjectKey) {
            settings = CDO_Settings__c.getOrgDefaults();
            project = [SELECT Id, Name, Key__c FROM CDO_Project__c WHERE Key__c = :existingProjectKey];
            Map<String, CDO_Environment__c> envByKey = new Map<String, CDO_Environment__c>();
            for (CDO_Environment__c e : [
                SELECT Id, Name, Key__c, Pipeline_Key__c, Health_Status__c, Last_Deployment__c, Last_Deployed_On__c
                FROM CDO_Environment__c
                WHERE Project__c = :project.Id
            ]) {
                envByKey.put(e.Pipeline_Key__c, e);
            }
            envInt = envByKey.get('int');
            envQa = envByKey.get('qa');
            envStage = envByKey.get('stage');
            envProd = envByKey.get('prod');
            environments = new List<CDO_Environment__c>{ envInt, envQa, envStage, envProd };
            stages = [
                SELECT Id, Name, Project__c, Pipeline_Key__c, Order__c, Environment__c, Is_Entry__c, Is_Production__c, Branch__c
                FROM CDO_Stage__c
                WHERE Project__c = :project.Id
                ORDER BY Order__c ASC
            ];
            for (CDO_Stage__c s : stages) {
                if (s.Pipeline_Key__c == 'int') {
                    stageInt = s;
                } else if (s.Pipeline_Key__c == 'qa') {
                    stageQa = s;
                } else if (s.Pipeline_Key__c == 'stage') {
                    stageStage = s;
                } else if (s.Pipeline_Key__c == 'prod') {
                    stageProd = s;
                }
            }
            workItems = queryWorkItems(project.Id);
        }

        private CDO_Environment__c newEnvironment(String key, String envType) {
            return new CDO_Environment__c(
                Name = key.toUpperCase(),
                Key__c = PROJECT_KEY + ':' + key,
                Project__c = project.Id,
                Pipeline_Key__c = key,
                Type__c = envType,
                Branch__c = key == 'prod' ? 'main' : key,
                GitHub_Environment__c = key,
                Org_Alias__c = 'sfp-' + key,
                Test_Level__c = 'RunSpecifiedTests'
            );
        }

        private CDO_Stage__c newStage(String name, String key, String branch, Integer order, CDO_Environment__c env, String gate) {
            return new CDO_Stage__c(
                Name = name,
                Key__c = PROJECT_KEY + ':' + key,
                Project__c = project.Id,
                Environment__c = env.Id,
                Order__c = order,
                Gate_Type__c = gate,
                Coverage_Floor__c = 85,
                Pipeline_Key__c = key,
                Branch__c = branch,
                Test_Level__c = 'RunSpecifiedTests'
            );
        }

        private List<CDO_Work_Item__c> queryWorkItems(Id projectId) {
            return [
                SELECT Id, Name, Subject__c, Status__c, Project__c, Current_Stage__c, Feature_Branch__c, Source_Org_Alias__c
                FROM CDO_Work_Item__c
                WHERE Project__c = :projectId
                ORDER BY Name
            ];
        }
    }

    public static TestData loadData() {
        return new TestData(PROJECT_KEY);
    }

    // ---- Callout mock ------------------------------------------------------------------------------

    public class GitHubMock implements HttpCalloutMock {
        public Integer dispatchStatus = 204;
        public Integer runsStatus = 200;
        public String runsBody = '{"total_count":0,"workflow_runs":[]}';
        public Integer runStatus = 200;
        public String runBody = '{}';
        public Integer repoStatus = 200;
        public Integer webhookStatus = 200;
        public Boolean throwError = false;

        public HttpResponse respond(HttpRequest req) {
            calls.add(req);
            if (throwError) {
                throw new CalloutException('Simulated network failure');
            }
            String endpoint = req.getEndpoint();
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (endpoint.contains('/dispatches')) {
                res.setStatusCode(dispatchStatus);
                res.setStatus(dispatchStatus == 204 ? 'No Content' : 'Unprocessable Entity');
                res.setBody(dispatchStatus == 204 ? '' : '{"message":"Unexpected inputs provided"}');
            } else if (endpoint.contains('/actions/runs/')) {
                res.setStatusCode(runStatus);
                res.setStatus('OK');
                res.setBody(runBody);
            } else if (endpoint.contains('/actions/runs')) {
                res.setStatusCode(runsStatus);
                res.setStatus(runsStatus == 200 ? 'OK' : 'Server Error');
                res.setBody(runsBody);
            } else if (endpoint.contains('/repos/')) {
                res.setStatusCode(repoStatus);
                res.setStatus('OK');
                res.setBody('{"full_name":"acme/sfdevops-sample"}');
            } else {
                res.setStatusCode(webhookStatus);
                res.setStatus('OK');
                res.setBody('ok');
            }
            return res;
        }
    }

    /** One workflow run as the GitHub REST API returns it. */
    public static Map<String, Object> run(Long id, String title, String status, String conclusion) {
        return new Map<String, Object>{
            'id' => id,
            'name' => 'SF Promotion',
            'display_title' => title,
            'html_url' => 'https://github.com/acme/sfdevops-sample/actions/runs/' + id,
            'status' => status,
            'conclusion' => conclusion
        };
    }

    public static String runsJson(List<Map<String, Object>> runs) {
        return JSON.serialize(new Map<String, Object>{ 'total_count' => runs.size(), 'workflow_runs' => runs });
    }

    // ---- REST helpers ----------------------------------------------------------------------------------

    public static RestResponse postCallback(Map<String, Object> body) {
        return invoke('/services/apexrest/cdo/deploy-callback', body == null ? null : JSON.serialize(body), 'callback');
    }

    public static RestResponse postMergeStatus(Map<String, Object> body) {
        return invoke('/services/apexrest/cdo/merge-status', body == null ? null : JSON.serialize(body), 'merge');
    }

    public static RestResponse postSourceMembers(Map<String, Object> body) {
        return invoke('/services/apexrest/cdo/source-members', body == null ? null : JSON.serialize(body), 'members');
    }

    public static RestResponse postRaw(String resource, String body) {
        return invoke('/services/apexrest/cdo/' + resource, body, resource == 'merge-status' ? 'merge' : (resource == 'source-members' ? 'members' : 'callback'));
    }

    private static RestResponse invoke(String uri, String body, String which) {
        RestRequest req = new RestRequest();
        req.requestURI = uri;
        req.httpMethod = 'POST';
        if (body != null) {
            req.requestBody = Blob.valueOf(body);
        }
        RestContext.request = req;
        RestContext.response = new RestResponse();
        if (which == 'merge') {
            CDO_MergeStatusResource.handleMergeStatus();
        } else if (which == 'members') {
            CDO_SourceMemberResource.handleSourceMembers();
        } else {
            CDO_CallbackResource.handleCallback();
        }
        return RestContext.response;
    }

    public static Map<String, Object> body(RestResponse res) {
        return (Map<String, Object>) JSON.deserializeUntyped(res.responseBody.toString());
    }

    public static Map<String, Object> event(String eventType, String status, String workItem, String environment) {
        Map<String, Object> m = new Map<String, Object>{ 'eventType' => eventType, 'status' => status };
        if (workItem != null) {
            m.put('workItem', workItem);
        }
        if (environment != null) {
            m.put('environment', environment);
        }
        return m;
    }

    public static Map<String, Object> promotionEvent(Id promotionId, String eventType, String status) {
        return new Map<String, Object>{ 'promotionId' => promotionId, 'eventType' => eventType, 'status' => status };
    }

    // ---- Record helpers ------------------------------------------------------------------------------

    public static CDO_Work_Item__c workItem(Id workItemId) {
        return [
            SELECT Id, Name, Status__c, Current_Stage__c, Merge_State__c, Feature_Branch__c, Last_Commit_SHA__c,
                Blocked_Reason__c, Conflict_Paths__c, Pull_Request_URL__c, Pull_Request_Number__c,
                Pull_Requests_Approved__c, Review_State__c, Last_Coverage__c, Last_Tests_Passed__c,
                Last_Validation_Status__c, Last_Run_URL__c, Source_Changes_JSON__c, Source_Changes_Status__c,
                Source_Changes_Received_On__c
            FROM CDO_Work_Item__c
            WHERE Id = :workItemId
        ];
    }

    public static CDO_Environment__c environment(Id environmentId) {
        return [
            SELECT Id, Health_Status__c, Last_Deployment__c, Last_Deployed_On__c FROM CDO_Environment__c WHERE Id = :environmentId
        ];
    }

    public static CDO_Promotion__c promotion(Id promotionId) {
        return [
            SELECT Id, Name, Status__c, Message__c, Merge_SHA__c, Completed_On__c, Dispatched_On__c, Workflow_Run_URL__c,
                Promotion_Branch__c, Target_SHA_At_Cut__c, Target_Stage__c, Source_Stage__c, Direction__c, Check_Only__c,
                Allow_Destructive__c, Test_Level__c, Specified_Tests__c, Requested_By__c,
                (SELECT Id, Work_Item__c, Status__c, Unique_Key__c FROM Promoted_Work_Items__r)
            FROM CDO_Promotion__c
            WHERE Id = :promotionId
        ];
    }

    public static Integer auditCount(String eventType) {
        return [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = :eventType];
    }

    public static Id fakeId(Schema.SObjectType t) {
        return Id.valueOf(t.getDescribe().getKeyPrefix() + '000000000000');
    }

    private static void placeAt(CDO_Work_Item__c wi, CDO_Stage__c stage) {
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = stage.Id, Status__c = 'Deployed', Last_Commit_SHA__c = 'abc1234');
    }

    @testSetup
    static void setup() {
        new TestData();
    }

    // =====================================================================================================
    // GitHubService
    // =====================================================================================================

    @isTest
    static void dispatchWorkflowSendsTheContractRequest() {
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        Test.startTest();
        GitHubService.DispatchResult r = GitHubService.dispatchWorkflow(
            GitHubService.WF_COMMIT,
            null,
            new Map<String, String>{ 'work_item' => 'WI-0001', 'empty' => null }
        );
        Test.stopTest();
        Assert.isTrue(r.ok, r.message);
        Assert.areEqual(204, r.statusCode);
        HttpRequest sent = calls[0];
        Assert.areEqual('callout:GitHub_API/repos/acme/sfdevops-sample/actions/workflows/sf-commit.yml/dispatches', sent.getEndpoint());
        Assert.areEqual('POST', sent.getMethod());
        Assert.areEqual('application/vnd.github+json', sent.getHeader('Accept'));
        Assert.areEqual('2022-11-28', sent.getHeader('X-GitHub-Api-Version'));
        Assert.areEqual('application/json', sent.getHeader('Content-Type'));
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(sent.getBody());
        Assert.areEqual('main', payload.get('ref'));
        Map<String, Object> inputs = (Map<String, Object>) payload.get('inputs');
        Assert.areEqual('WI-0001', inputs.get('work_item'));
        Assert.areEqual('', inputs.get('empty'), 'null inputs are sent as empty strings');
        for (Object v : inputs.values()) {
            Assert.isTrue(v instanceof String, 'every input is a string');
        }
    }

    @isTest
    static void dispatchWorkflowReportsFailuresWithoutThrowing() {
        GitHubMock mock = new GitHubMock();
        mock.dispatchStatus = 422;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        GitHubService.DispatchResult refused = GitHubService.dispatchWorkflow(GitHubService.WF_PROMOTION, 'main', null);
        Assert.isFalse(refused.ok);
        Assert.areEqual(422, refused.statusCode);
        Assert.isTrue(refused.message.contains('HTTP 422'), refused.message);

        mock.dispatchStatus = 200;
        Assert.isFalse(GitHubService.dispatchWorkflow(GitHubService.WF_PROMOTION, 'main', null).ok, 'only 204 is success');

        mock.throwError = true;
        GitHubService.DispatchResult unreachable = GitHubService.dispatchWorkflow(GitHubService.WF_PROMOTION, 'main', null);
        Assert.isFalse(unreachable.ok);
        Assert.areEqual(0, unreachable.statusCode);
        Assert.areEqual(0, GitHubService.send('GET', '/actions/runs', null).getStatusCode());

        Assert.isFalse(GitHubService.dispatchWorkflow('  ', 'main', null).ok);
        Assert.isFalse(new GitHubService.DispatchResult().ok);
        Test.stopTest();
    }

    @isTest
    static void dispatchIsRefusedWhenDisabledOrUnconfigured() {
        CDO_Settings__c s = CDO_Settings__c.getOrgDefaults();
        s.Dispatch_Enabled__c = false;
        update s;
        GitHubService.DispatchResult disabled = GitHubService.dispatchWorkflow(GitHubService.WF_COMMIT, null, null);
        Assert.isFalse(disabled.ok);
        Assert.isTrue(disabled.message.contains('Dispatch Enabled'), disabled.message);

        delete s;
        GitHubService.DispatchResult missing = GitHubService.dispatchWorkflow(GitHubService.WF_COMMIT, null, null);
        Assert.isFalse(missing.ok);
        Assert.isTrue(missing.message.contains('not configured'), missing.message);
        Assert.isNull(GitHubService.repoUrl());
        Assert.areEqual(0, GitHubService.send('GET', '', null).getStatusCode());
        Assert.isFalse(GitHubService.testConnection());
        Assert.areEqual('main', GitHubService.defaultRef());
        Assert.areEqual('GitHub_API', GitHubService.namedCredential());
    }

    @isTest
    static void connectionHelpersUseTheRepository() {
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        Test.startTest();
        Assert.isTrue(GitHubService.testConnection());
        Assert.areEqual('callout:GitHub_API/repos/acme/sfdevops-sample', calls[0].getEndpoint());
        Assert.areEqual('https://github.com/acme/sfdevops-sample', GitHubService.repoUrl());
        HttpResponse res = GitHubService.send('get', 'actions/runs', null);
        Assert.areEqual(200, res.getStatusCode());
        Assert.isTrue(calls[1].getEndpoint().endsWith('/repos/acme/sfdevops-sample/actions/runs'));
        Assert.areEqual('GET', calls[1].getMethod());
        Assert.areEqual(0, GitHubService.stringInputs(null).size());
        Test.stopTest();
    }

    @isTest
    static void dispatchJobAuditsWhatItSent() {
        loadData();
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        Test.startTest();
        System.enqueueJob(
            new GitHubService.DispatchJob(GitHubService.WF_SYNC_ENV, null, new Map<String, String>{ 'target_env' => 'qa', 'deploy' => null })
        );
        Test.stopTest();
        CDO_Audit_Event__c ev = [SELECT Summary__c, Details__c, Source__c FROM CDO_Audit_Event__c WHERE Event_Type__c = 'WorkflowDispatched'];
        Map<String, Object> details = (Map<String, Object>) JSON.deserializeUntyped(ev.Details__c);
        Assert.areEqual(GitHubService.WF_SYNC_ENV, details.get('workflow'));
        Assert.areEqual(204, details.get('statusCode'));
        Map<String, Object> inputs = (Map<String, Object>) details.get('inputs');
        Assert.areEqual('qa', inputs.get('target_env'));
        Assert.areEqual('', inputs.get('deploy'));
        Assert.areEqual('Hub', ev.Source__c);
    }

    @isTest
    static void dispatchJobStampsRefusalsOnTheRequestingRecord() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        update new CDO_Work_Item__c(Id = wi.Id, Source_Changes_Status__c = 'Requested');
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageQa.Id, Status__c = 'Dispatched', Dispatched_On__c = System.now());
        insert p;
        insert CDOPromotionDispatcher.junctionRows(p.Id, new List<CDO_Work_Item__c>{ wi });
        CDO_Release__c rel = new CDO_Release__c(Name = 'R1', Project__c = d.project.Id, Status__c = 'Validating');
        insert rel;
        CDO_Data_Set__c ds = new CDO_Data_Set__c(Name = 'Accounts', Project__c = d.project.Id, Status__c = 'Deploying');
        insert ds;
        CDO_Deployment__c dep = new CDO_Deployment__c(Status__c = 'Running', Stage__c = d.stageQa.Id);
        insert dep;

        GitHubMock mock = new GitHubMock();
        mock.dispatchStatus = 422;
        Test.setMock(HttpCalloutMock.class, mock);
        List<GitHubService.DispatchRequest> requests = new List<GitHubService.DispatchRequest>{
            new GitHubService.DispatchRequest(GitHubService.WF_PROMOTION, null, null, p.Id),
            new GitHubService.DispatchRequest(GitHubService.WF_LIST_CHANGES, null, null, wi.Id),
            new GitHubService.DispatchRequest(GitHubService.WF_PROD_RELEASE, null, null, rel.Id),
            new GitHubService.DispatchRequest(GitHubService.WF_DATA_DEPLOY, null, null, ds.Id),
            new GitHubService.DispatchRequest(GitHubService.WF_OPS_ROLLBACK, null, null, dep.Id),
            new GitHubService.DispatchRequest(GitHubService.WF_SYNC_ENV, null, null, null)
        };
        Test.startTest();
        System.enqueueJob(new GitHubService.DispatchJob(requests));
        Test.stopTest();

        CDO_Promotion__c failed = promotion(p.Id);
        Assert.areEqual('Failed', failed.Status__c);
        Assert.isTrue(failed.Message__c.contains('422'), failed.Message__c);
        Assert.isNotNull(failed.Completed_On__c);
        Assert.areEqual('Failed', workItem(wi.Id).Source_Changes_Status__c);
        Assert.areEqual('Failed', [SELECT Status__c FROM CDO_Release__c WHERE Id = :rel.Id].Status__c);
        Assert.areEqual('Failed', [SELECT Status__c FROM CDO_Data_Set__c WHERE Id = :ds.Id].Status__c);
        Assert.areEqual('Failed', [SELECT Status__c FROM CDO_Deployment__c WHERE Id = :dep.Id].Status__c);
        Assert.areEqual(6, auditCount('WorkflowDispatchFailed'));
    }

    @isTest
    static void dispatchJobRequeuesWhenNothingReachedGitHub() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        placeAt(wi, d.stageInt);
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        Test.startTest();
        Id promotionId = CDOPromotionDispatcher.requestPromotion(new List<Id>{ wi.Id }, d.stageQa.Id, null, true);
        Assert.areEqual('Dispatched', promotion(promotionId).Status__c);
        CDO_Settings__c s = CDO_Settings__c.getOrgDefaults();
        s.Dispatch_Enabled__c = false;
        update s;
        Test.stopTest();
        CDO_Promotion__c p = promotion(promotionId);
        Assert.areEqual('Queued', p.Status__c, 'a dispatch that never reached GitHub goes back in the queue');
        Assert.isNull(p.Dispatched_On__c);
        Assert.isTrue(p.Message__c.startsWith('Not dispatched'), p.Message__c);
    }

    @isTest
    static void dispatchJobChainsWhenThereAreManyRequests() {
        loadData();
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        List<GitHubService.DispatchRequest> requests = new List<GitHubService.DispatchRequest>();
        for (Integer i = 0; i < GitHubService.MAX_DISPATCHES_PER_JOB + 2; i++) {
            requests.add(new GitHubService.DispatchRequest(GitHubService.WF_CONFLICT_CHECK, 'main', new Map<String, String>{ 'work_items' => 'WI-' + i }, null));
        }
        GitHubService.DispatchJob job = new GitHubService.DispatchJob(requests);
        Test.startTest();
        System.enqueueJob(job);
        Test.stopTest();
        Assert.areEqual(GitHubService.MAX_DISPATCHES_PER_JOB, auditCount('WorkflowDispatched'), 'the rest go to a chained job');
    }

    // =====================================================================================================
    // CDO_Audit
    // =====================================================================================================

    @isTest
    static void auditIsBulkSafeAndStampsDefaults() {
        TestData d = loadData();
        Id wiId = d.workItems[0].Id;
        CDO_Audit.hold();
        for (Integer i = 0; i < 20; i++) {
            CDO_Audit.log('Bulk', 'Event ' + i, null, new Map<String, Id>{ 'workItem' => wiId });
        }
        Assert.areEqual(0, auditCount('Bulk'), 'nothing is written while held');
        Integer dmlBefore = Limits.getDmlStatements();
        CDO_Audit.release();
        Assert.areEqual(dmlBefore + 1, Limits.getDmlStatements(), 'one insert for the whole batch');
        Assert.areEqual(20, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = 'Bulk' AND Work_Item__c = :wiId AND Source__c = 'Hub']);

        CDO_Audit.setSource(CDO_Audit.SOURCE_GITHUB);
        CDO_Audit.log('X'.repeat(100), 'S'.repeat(400), 'D', new Map<String, Id>{ 'promotion' => wiId, 'release' => null });
        CDO_Audit.setSource(null);
        CDO_Audit.log((CDO_Audit_Event__c) null);
        CDO_Audit.log((List<CDO_Audit_Event__c>) null);
        CDO_Audit.flush();
        CDO_Audit_Event__c ev = [
            SELECT Event_Type__c, Summary__c, Source__c, Actor__c, Work_Item__c, Promotion__c, Occurred_On__c
            FROM CDO_Audit_Event__c
            WHERE Source__c = 'GitHub'
        ];
        Assert.areEqual(80, ev.Event_Type__c.length());
        Assert.areEqual(255, ev.Summary__c.length());
        Assert.areEqual(wiId, ev.Work_Item__c, 'an Id is filed by its own type, whatever the key');
        Assert.isNull(ev.Promotion__c);
        Assert.areEqual(UserInfo.getName(), ev.Actor__c);
        Assert.isNotNull(ev.Occurred_On__c);

        CDO_Audit_Event__c custom = CDO_Audit.build('Custom', 'Custom event', null, null);
        custom.Actor__c = 'octocat';
        custom.Run_URL__c = 'https://example.com/' + 'x'.repeat(300);
        CDO_Audit.log(custom);
        CDO_Audit_Event__c stored = [SELECT Actor__c, Run_URL__c FROM CDO_Audit_Event__c WHERE Event_Type__c = 'Custom'];
        Assert.areEqual('octocat', stored.Actor__c);
        Assert.isNull(stored.Run_URL__c, 'an over-long URL is dropped, not truncated');
    }

    // =====================================================================================================
    // CDO_CallbackResource / CDO_CallbackService
    // =====================================================================================================

    @isTest
    static void callbackRejectsBadInputWithJson() {
        TestData d = loadData();
        Assert.areEqual(400, postRaw('deploy-callback', null).statusCode);
        RestResponse malformed = postRaw('deploy-callback', '{not json');
        Assert.areEqual(400, malformed.statusCode);
        Assert.isFalse((Boolean) body(malformed).get('success'));
        Assert.areEqual(400, postRaw('deploy-callback', 'null').statusCode);
        Assert.areEqual(400, postCallback(new Map<String, Object>{ 'status' => 'Running' }).statusCode, 'no identifiers');
        Assert.areEqual(400, postCallback(promotionEvent(fakeId(CDO_Promotion__c.SObjectType), 'Deploy', 'Running')).statusCode, 'unknown promotion');
        Assert.areEqual(400, postCallback(new Map<String, Object>{ 'promotionId' => 'not-an-id', 'status' => 'Running' }).statusCode);
        Assert.areEqual(400, postCallback(new Map<String, Object>{ 'promotionId' => d.workItems[0].Id, 'status' => 'Running' }).statusCode, 'wrong object');
        Assert.areEqual(400, postCallback(event('Deploy', 'Exploded', d.workItems[0].Name, 'int')).statusCode, 'unknown status');
        Assert.areEqual(400, postCallback(event('Commit', 'Success', 'WI-9999', 'dev')).statusCode, 'unknown work item');
        Assert.areEqual(400, postCallback(event(null, 'Success', d.workItems[0].Name, 'dev')).statusCode, 'no event type');
        Assert.areEqual(400, postCallback(event('Deploy', null, d.workItems[0].Name, 'qa')).statusCode, 'no status');
        Assert.areEqual(400, postCallback(event('Release', 'Success', d.workItems[0].Name, 'prod')).statusCode, 'release without id');
        Assert.areEqual(400, postCallback(event('Commit', 'Success', d.workItems[0].Name, 'dev')).statusCode, 'commit without sha');
        Map<String, Object> badRelease = event('Release', 'Success', null, 'prod');
        badRelease.put('releaseId', fakeId(CDO_Release__c.SObjectType));
        Assert.areEqual(400, postCallback(badRelease).statusCode);
        Assert.isTrue(auditCount('CallbackRejected') >= 12);

        RestResponse unknownEvent = postCallback(event('Telemetry', 'Success', d.workItems[0].Name, 'int'));
        Assert.areEqual(200, unknownEvent.statusCode, 'a newer pipeline event is recorded, not refused');
        Assert.isTrue(((String) body(unknownEvent).get('message')).contains('not handled'));
        Assert.areEqual(1, auditCount('Callback.Telemetry.Success'));
    }

    @isTest
    static void validationRunningThenSuccessLeavesOneRowAndNoHealth() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        RestResponse first = postCallback(event('Validation', 'Running', wi.Name, 'int'));
        Assert.areEqual(200, first.statusCode, first.responseBody.toString());
        Assert.areEqual('Running', workItem(wi.Id).Last_Validation_Status__c);

        Map<String, Object> success = event('Validation', 'Success', wi.Name, 'int');
        success.put('coveragePercent', 87.5);
        success.put('testsPassed', true);
        success.put('deployId', '0Af000000000001AAA');
        success.put('testLevel', 'RunSpecifiedTests');
        success.put('runUrl', RUN_URL);
        success.put('findings', new List<Object>{
            new Map<String, Object>{ 'tool' => 'pmd', 'rule' => 'ApexCRUDViolation', 'severity' => '3', 'file' => 'force-app/main/default/classes/Foo.cls', 'line' => 12, 'message' => 'Validate CRUD' },
            new Map<String, Object>{ 'tool' => 'SonarQube', 'rule' => 'S1234', 'severity' => 'blocker', 'file' => 'x', 'message' => 'Fix' }
        });
        RestResponse second = postCallback(success);
        Assert.areEqual(200, second.statusCode, second.responseBody.toString());

        List<CDO_Deployment__c> deps = [
            SELECT Id, Status__c, Check_Only__c, Event_Type__c, Coverage_Percent__c, Stage__c, Environment__c, Completed_On__c
            FROM CDO_Deployment__c
            WHERE Work_Item__c = :wi.Id
        ];
        Assert.areEqual(1, deps.size(), 'Running -> Success without a run URL leaves one row');
        Assert.areEqual('Success', deps[0].Status__c);
        Assert.isTrue(deps[0].Check_Only__c);
        Assert.areEqual('Validation', deps[0].Event_Type__c);
        Assert.isTrue(deps[0].Coverage_Percent__c == 87.5, 'literal percent');
        Assert.areEqual(d.stageInt.Id, deps[0].Stage__c);
        Assert.areEqual(d.envInt.Id, deps[0].Environment__c);
        Assert.isNotNull(deps[0].Completed_On__c);
        Assert.areEqual(String.valueOf(deps[0].Id), body(first).get('deploymentId'));
        Assert.areEqual(String.valueOf(deps[0].Id), body(second).get('deploymentId'));

        CDO_Work_Item__c after = workItem(wi.Id);
        Assert.areEqual('Passed', after.Last_Validation_Status__c);
        Assert.isTrue(after.Last_Coverage__c == 87.5);
        Assert.isTrue(after.Last_Tests_Passed__c);
        List<CDO_Scan_Finding__c> findings = [
            SELECT Tool__c, Severity__c, Line__c, Deployment__c FROM CDO_Scan_Finding__c WHERE Work_Item__c = :wi.Id ORDER BY Tool__c
        ];
        Assert.areEqual(2, findings.size());
        Assert.areEqual('PMD', findings[0].Tool__c);
        Assert.areEqual('Medium', findings[0].Severity__c);
        Assert.areEqual('Sonar', findings[1].Tool__c);
        Assert.areEqual('Critical', findings[1].Severity__c);

        // Resending the same result replaces the findings instead of doubling them.
        postCallback(success);
        Assert.areEqual(2, [SELECT COUNT() FROM CDO_Scan_Finding__c WHERE Work_Item__c = :wi.Id]);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Deployment__c WHERE Work_Item__c = :wi.Id]);

        Assert.isNull(environment(d.envInt.Id).Health_Status__c, 'a validation never touches environment health');
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Audit_Event__c WHERE Event_Type__c = 'Callback.Validation.Running' AND Source__c = 'GitHub' AND Work_Item__c = :wi.Id]);

        Assert.areEqual(RUN_URL, workItem(wi.Id).Last_Run_URL__c);
        Map<String, Object> failed = event('Validation', 'Failed', wi.Name, 'int');
        failed.put('runUrl', RUN_URL_2);
        postCallback(failed);
        Assert.areEqual('Failed', workItem(wi.Id).Last_Validation_Status__c);
        Assert.areEqual(RUN_URL_2, workItem(wi.Id).Last_Run_URL__c);
        postCallback(event('Validation', 'Cancelled', wi.Name, 'int'));
        Assert.areEqual('Not_Run', workItem(wi.Id).Last_Validation_Status__c);
    }

    @isTest
    static void environmentLevelDeployDedupsOnRunUrlAndSetsHealth() {
        TestData d = loadData();
        Assert.isNull(environment(d.envQa.Id).Health_Status__c, 'blank before anything is deployed');
        Map<String, Object> running = event('Rollback', 'Running', null, 'qa');
        running.put('runUrl', RUN_URL);
        Assert.areEqual(200, postCallback(running).statusCode);
        Assert.isNull(environment(d.envQa.Id).Health_Status__c, 'Running does not touch health');
        Map<String, Object> done = event('Rollback', 'Success', null, 'qa');
        done.put('runUrl', RUN_URL);
        done.put('commitSha', 'abcdef1234567890');
        Assert.areEqual(200, postCallback(done).statusCode);
        List<CDO_Deployment__c> deps = [SELECT Id, Status__c, Event_Type__c, Work_Item__c, Environment__c FROM CDO_Deployment__c WHERE Stage__c = :d.stageQa.Id];
        Assert.areEqual(1, deps.size());
        Assert.areEqual('Success', deps[0].Status__c);
        Assert.areEqual('Rollback', deps[0].Event_Type__c);
        Assert.isNull(deps[0].Work_Item__c);
        CDO_Environment__c env = environment(d.envQa.Id);
        Assert.areEqual('Healthy', env.Health_Status__c);
        Assert.areEqual(deps[0].Id, env.Last_Deployment__c);
        Assert.isNotNull(env.Last_Deployed_On__c);

        // An ops redeploy of a work item to a non-entry stage records a row and degrades on failure.
        Map<String, Object> redeploy = event('Deploy', 'Failed', d.workItems[1].Name, 'stage');
        redeploy.put('message', 'Component failure');
        Assert.areEqual(200, postCallback(redeploy).statusCode);
        Assert.areEqual('Degraded', environment(d.envStage.Id).Health_Status__c);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Deployment__c WHERE Work_Item__c = :d.workItems[1].Id AND Stage__c = :d.stageStage.Id AND Status__c = 'Failed']);
        Assert.areEqual(0, [SELECT COUNT() FROM CDO_Promotion__c], 'only the entry stage creates a promotion from a deploy event');

        // An unknown environment is recorded without a stage and leaves every environment alone.
        Assert.areEqual(200, postCallback(event('Deploy', 'Success', null, 'nowhere')).statusCode);
    }

    @isTest
    static void promotionRunningThenSuccessResolvesAndMovesTheQueue() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        CDO_Work_Item__c other = d.workItems[1];
        placeAt(wi, d.stageInt);
        placeAt(other, d.stageInt);
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        Id p1 = CDOPromotionDispatcher.requestPromotion(new List<Id>{ wi.Id }, d.stageQa.Id, null, true);
        Id p2 = CDOPromotionDispatcher.requestPromotion(new List<Id>{ other.Id }, d.stageQa.Id, null, true);
        Assert.areEqual('Dispatched', promotion(p1).Status__c);
        Assert.areEqual('Queued', promotion(p2).Status__c, 'one promotion in flight per stage');

        Map<String, Object> running = promotionEvent(p1, 'Deploy', 'Running');
        running.put('environment', 'qa');
        running.put('promotionBranch', 'promotion/' + wi.Name + '-to-qa');
        running.put('targetShaAtCut', 'aaaabbbbccccdddd');
        Assert.areEqual(200, postCallback(running).statusCode);
        CDO_Promotion__c deploying = promotion(p1);
        Assert.areEqual('Deploying', deploying.Status__c);
        Assert.areEqual('promotion/' + wi.Name + '-to-qa', deploying.Promotion_Branch__c);
        Assert.areEqual('aaaabbbbccccdddd', deploying.Target_SHA_At_Cut__c);
        Assert.isNull(environment(d.envQa.Id).Health_Status__c);

        Map<String, Object> success = promotionEvent(p1, 'Deploy', 'Success');
        success.put('runUrl', RUN_URL);
        success.put('commitSha', '1111222233334444555566667777888899990000');
        RestResponse res = postCallback(success);
        Assert.areEqual(200, res.statusCode, res.responseBody.toString());

        List<CDO_Deployment__c> deps = [SELECT Id, Status__c, Workflow_Run_URL__c, Work_Item__c, Stage__c FROM CDO_Deployment__c WHERE Promotion__c = :p1];
        Assert.areEqual(1, deps.size(), 'the Running -> Success pair leaves one deployment row');
        Assert.areEqual('Success', deps[0].Status__c);
        Assert.areEqual(RUN_URL, deps[0].Workflow_Run_URL__c);
        Assert.areEqual(wi.Id, deps[0].Work_Item__c);
        CDO_Promotion__c deployed = promotion(p1);
        Assert.areEqual('Deployed', deployed.Status__c);
        Assert.areEqual('1111222233334444555566667777888899990000', deployed.Merge_SHA__c);
        Assert.isNotNull(deployed.Completed_On__c);
        Assert.areEqual('Deployed', deployed.Promoted_Work_Items__r[0].Status__c);
        CDO_Work_Item__c moved = workItem(wi.Id);
        Assert.areEqual(d.stageQa.Id, moved.Current_Stage__c);
        Assert.areEqual('Deployed', moved.Status__c);
        Assert.areEqual('Merged', moved.Merge_State__c);
        CDO_Environment__c env = environment(d.envQa.Id);
        Assert.areEqual('Healthy', env.Health_Status__c);
        Assert.areEqual(deps[0].Id, env.Last_Deployment__c);
        Assert.areEqual('Dispatched', promotion(p2).Status__c, 'the next queued promotion goes when the stage frees up');

        // A repeated success is idempotent; a late Running does not reopen it.
        Assert.areEqual(200, postCallback(success).statusCode);
        Assert.areEqual(200, postCallback(running).statusCode);
        Assert.areEqual('Deployed', promotion(p1).Status__c);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Deployment__c WHERE Promotion__c = :p1]);
        Assert.areEqual('Success', [SELECT Status__c FROM CDO_Deployment__c WHERE Promotion__c = :p1].Status__c);
    }

    @isTest
    static void promotionFailureBlocksWorkItemsAndDegradesTheEnvironment() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        placeAt(wi, d.stageInt);
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        Id p = CDOPromotionDispatcher.requestPromotion(new List<Id>{ wi.Id }, d.stageQa.Id, null, true);
        Map<String, Object> failed = promotionEvent(p, 'Deploy', 'Failed');
        failed.put('message', 'Apex test failure');
        failed.put('failingMethods', 'FooTest.bar: boom');
        failed.put('coveragePercent', 61);
        failed.put('testsPassed', false);
        failed.put('componentCount', 3);
        Assert.areEqual(200, postCallback(failed).statusCode);
        CDO_Promotion__c after = promotion(p);
        Assert.areEqual('Failed', after.Status__c);
        Assert.areEqual('Apex test failure', after.Message__c);
        Assert.areEqual('Failed', after.Promoted_Work_Items__r[0].Status__c);
        CDO_Work_Item__c blocked = workItem(wi.Id);
        Assert.areEqual('Blocked', blocked.Status__c);
        Assert.isTrue(blocked.Blocked_Reason__c.contains('Apex test failure'));
        Assert.areEqual(d.stageInt.Id, blocked.Current_Stage__c, 'a failed promotion moves nothing');
        Assert.areEqual('Degraded', environment(d.envQa.Id).Health_Status__c);
        CDO_Deployment__c dep = [SELECT Status__c, Failing_Methods__c, Tests_Passed__c, Component_Count__c FROM CDO_Deployment__c WHERE Promotion__c = :p];
        Assert.areEqual('Failed', dep.Status__c);
        Assert.areEqual('FooTest.bar: boom', dep.Failing_Methods__c);
        Assert.isTrue(dep.Component_Count__c == 3);
    }

    @isTest
    static void promotionConflictMarksWorkItemsAndComponents() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        placeAt(wi, d.stageInt);
        String path = 'force-app/main/default/classes/Foo.cls';
        insert new CDO_Component__c(Name = 'ApexClass:Foo', Work_Item__c = wi.Id, Metadata_Type__c = 'ApexClass', Member_Name__c = 'Foo', Unique_ID__c = 'ApexClass:Foo', Work_Item_Key__c = wi.Name + '|ApexClass:Foo', Path__c = path);
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        Id p = CDOPromotionDispatcher.requestPromotion(new List<Id>{ wi.Id }, d.stageQa.Id, null, true);
        postCallback(promotionEvent(p, 'Deploy', 'Running'));
        Map<String, Object> conflict = promotionEvent(p, 'Conflict', 'Failed');
        conflict.put('conflictPaths', path + '\nforce-app/main/default/layouts/Bar.layout-meta.xml');
        Assert.areEqual(200, postCallback(conflict).statusCode);
        CDO_Promotion__c after = promotion(p);
        Assert.areEqual('Conflict', after.Status__c);
        Assert.areEqual('Conflict', after.Promoted_Work_Items__r[0].Status__c);
        CDO_Work_Item__c item = workItem(wi.Id);
        Assert.areEqual('Conflict', item.Merge_State__c);
        Assert.areEqual('Blocked', item.Status__c);
        Assert.isTrue(item.Conflict_Paths__c.contains(path));
        Assert.isTrue([SELECT Has_Conflict__c FROM CDO_Component__c WHERE Work_Item__c = :wi.Id].Has_Conflict__c);
        Assert.areEqual('Failed', [SELECT Status__c FROM CDO_Deployment__c WHERE Promotion__c = :p].Status__c, 'the open Running row is closed');
        Assert.isNull(environment(d.envQa.Id).Health_Status__c, 'a conflict deploys nothing');
    }

    @isTest
    static void checkOnlyAndCancelledPromotionsMoveNothing() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        CDO_Work_Item__c other = d.workItems[1];
        placeAt(wi, d.stageInt);
        placeAt(other, d.stageInt);
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        Id check = CDOPromotionDispatcher.requestPromotion(new List<Id>{ wi.Id }, d.stageQa.Id, new Map<String, String>{ 'checkOnly' => 'true' }, true);
        postCallback(promotionEvent(check, 'Validation', 'Running'));
        Assert.areEqual(200, postCallback(promotionEvent(check, 'Validation', 'Success')).statusCode);
        CDO_Promotion__c validated = promotion(check);
        Assert.areEqual('Deployed', validated.Status__c);
        Assert.isTrue(validated.Message__c.contains('Check-only'));
        Assert.areEqual(d.stageInt.Id, workItem(wi.Id).Current_Stage__c, 'a check-only run moves no work item');
        Assert.isNull(environment(d.envQa.Id).Health_Status__c);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Deployment__c WHERE Promotion__c = :check AND Check_Only__c = true]);

        Id cancel = CDOPromotionDispatcher.requestPromotion(new List<Id>{ other.Id }, d.stageQa.Id, null, true);
        Assert.areEqual(200, postCallback(promotionEvent(cancel, 'Deploy', 'Cancelled')).statusCode);
        Assert.areEqual('Cancelled', promotion(cancel).Status__c);
        Assert.areEqual('Deployed', workItem(other.Id).Status__c);
        Assert.isNull(environment(d.envQa.Id).Health_Status__c);

        Map<String, Object> mergeEvent = promotionEvent(check, 'Merge', 'Success');
        mergeEvent.put('commitSha', 'feedface');
        Assert.areEqual(200, postCallback(mergeEvent).statusCode);
        Assert.areEqual('feedface', promotion(check).Merge_SHA__c);
        Assert.areEqual(200, postCallback(promotionEvent(check, 'Telemetry', 'Success')).statusCode);
    }

    @isTest
    static void promotionCallbackHealsAMissingJunctionRow() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageQa.Id, Status__c = 'Dispatched');
        insert p;
        Map<String, Object> success = promotionEvent(p.Id, 'Deploy', 'Success');
        success.put('workItem', wi.Name);
        Assert.areEqual(200, postCallback(success).statusCode);
        CDO_Promotion__c after = promotion(p.Id);
        Assert.areEqual(1, after.Promoted_Work_Items__r.size(), 'the callback writes the missing junction row');
        Assert.areEqual(CDOPromotionDispatcher.junctionKey(p.Id, wi.Id), after.Promoted_Work_Items__r[0].Unique_Key__c);
        Assert.areEqual(d.stageQa.Id, workItem(wi.Id).Current_Stage__c, 'and the promotion resolves');
    }

    @isTest
    static void entryHopCreatesThePromotionAndJunctionFirst() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        Map<String, Object> running = event('Deploy', 'Running', wi.Name, 'int');
        running.put('runUrl', RUN_URL);
        running.put('pullRequestNumber', 7);
        running.put('promotionBranch', 'promotion/' + wi.Name + '-to-int');
        running.put('testLevel', 'runspecifiedtests');
        RestResponse first = postCallback(running);
        Assert.areEqual(200, first.statusCode, first.responseBody.toString());
        List<CDO_Promotion__c> promotions = [SELECT Id FROM CDO_Promotion__c];
        Assert.areEqual(1, promotions.size());
        CDO_Promotion__c p = promotion(promotions[0].Id);
        Assert.areEqual('Deploying', p.Status__c);
        Assert.areEqual(d.stageInt.Id, p.Target_Stage__c);
        Assert.areEqual('RunSpecifiedTests', p.Test_Level__c);
        Assert.areEqual(1, p.Promoted_Work_Items__r.size(), 'the entry-hop promotion has its junction row');
        Assert.areEqual(wi.Id, p.Promoted_Work_Items__r[0].Work_Item__c);
        Assert.areEqual(CDOPromotionDispatcher.junctionKey(p.Id, wi.Id), p.Promoted_Work_Items__r[0].Unique_Key__c);
        CDO_Deployment__c dep = [SELECT Id, Promotion__c, Status__c FROM CDO_Deployment__c];
        Assert.areEqual(p.Id, dep.Promotion__c);
        Assert.areEqual('Running', dep.Status__c);

        Map<String, Object> success = event('Deploy', 'Success', wi.Name, 'int');
        success.put('runUrl', RUN_URL);
        Assert.areEqual(200, postCallback(success).statusCode);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Promotion__c]);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Deployment__c]);
        Assert.areEqual('Deployed', promotion(p.Id).Status__c);
        CDO_Work_Item__c moved = workItem(wi.Id);
        Assert.areEqual(d.stageInt.Id, moved.Current_Stage__c);
        Assert.areEqual('Deployed', moved.Status__c);
        Assert.areEqual('Healthy', environment(d.envInt.Id).Health_Status__c);
    }

    @isTest
    static void entryHopMatchesTheOpenPromotionWithoutARunUrl() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        Assert.areEqual(200, postCallback(event('Deploy', 'Running', wi.Name, 'int')).statusCode);
        Map<String, Object> failed = event('Deploy', 'Failed', wi.Name, 'int');
        failed.put('runUrl', RUN_URL);
        failed.put('message', 'Validation failed');
        Assert.areEqual(200, postCallback(failed).statusCode);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Promotion__c]);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Deployment__c]);
        Assert.areEqual('Failed', [SELECT Status__c FROM CDO_Promotion__c].Status__c);
        Assert.areEqual('Blocked', workItem(wi.Id).Status__c);
        Assert.areEqual('Degraded', environment(d.envInt.Id).Health_Status__c);

        // A success that arrives with no Running before it still creates promotion + junction and resolves.
        CDO_Work_Item__c second = d.workItems[1];
        Assert.areEqual(200, postCallback(event('Deploy', 'Success', second.Name, 'int')).statusCode);
        CDO_Promotion__c p = [
            SELECT Id, Status__c, (SELECT Work_Item__c FROM Promoted_Work_Items__r)
            FROM CDO_Promotion__c
            WHERE Id IN (SELECT Promotion__c FROM CDO_Promoted_Work_Item__c WHERE Work_Item__c = :second.Id)
        ];
        Assert.areEqual('Deployed', p.Status__c);
        Assert.areEqual(1, p.Promoted_Work_Items__r.size());
        Assert.areEqual(d.stageInt.Id, workItem(second.Id).Current_Stage__c);
    }

    @isTest
    static void commitEventUpsertsCommitAndComponents() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        String sha = '0123456789abcdef0123456789abcdef01234567';
        Map<String, Object> commitEvent = event('Commit', 'Success', wi.Name, 'dev');
        commitEvent.put('commitSha', sha);
        commitEvent.put('message', wi.Name + ': add Foo\nlonger body');
        commitEvent.put('runUrl', RUN_URL);
        commitEvent.put('approver', 'octocat');
        commitEvent.put('components', new List<Object>{
            new Map<String, Object>{ 'type' => 'ApexClass', 'name' => 'Foo', 'action' => 'A', 'path' => 'force-app/main/default/classes/Foo.cls', 'lastCommitDate' => '2026-10-12T21:15:03.000Z' },
            new Map<String, Object>{ 'type' => 'CustomObject', 'name' => 'Bar__c', 'action' => 'modified', 'lastCommitDate' => '2026-10-12 21:15:03' },
            new Map<String, Object>{ 'type' => '', 'name' => 'ignored' }
        });
        RestResponse res = postCallback(commitEvent);
        Assert.areEqual(200, res.statusCode, res.responseBody.toString());
        CDO_Commit__c c = [SELECT Name, SHA__c, Branch__c, Component_Count__c, Workflow_Run_URL__c, Committed_By__c, Work_Item__c FROM CDO_Commit__c];
        Assert.areEqual(sha, c.SHA__c);
        Assert.isTrue(c.Name.startsWith('0123456 ' + wi.Name + ': add Foo'), c.Name);
        Assert.areEqual('feature/' + wi.Name, c.Branch__c);
        Assert.isTrue(c.Component_Count__c == 3);
        Assert.areEqual('octocat', c.Committed_By__c);
        Map<String, CDO_Component__c> byKey = new Map<String, CDO_Component__c>();
        for (CDO_Component__c comp : [SELECT Work_Item_Key__c, Unique_ID__c, Action__c, Path__c, Last_Commit_Date__c, Last_Commit_SHA__c FROM CDO_Component__c WHERE Work_Item__c = :wi.Id]) {
            byKey.put(comp.Work_Item_Key__c, comp);
        }
        Assert.areEqual(2, byKey.size());
        CDO_Component__c foo = byKey.get(wi.Name + '|ApexClass:Foo');
        Assert.areEqual('ApexClass:Foo', foo.Unique_ID__c);
        Assert.areEqual('Add', foo.Action__c);
        Assert.areEqual(Datetime.newInstanceGmt(2026, 10, 12, 21, 15, 3), foo.Last_Commit_Date__c);
        Assert.areEqual(sha, foo.Last_Commit_SHA__c);
        Assert.areEqual('Modify', byKey.get(wi.Name + '|CustomObject:Bar__c').Action__c);
        CDO_Work_Item__c after = workItem(wi.Id);
        Assert.areEqual('Committed', after.Status__c);
        Assert.areEqual('feature/' + wi.Name, after.Feature_Branch__c);
        Assert.areEqual(sha, after.Last_Commit_SHA__c);

        // The next commit updates the same component rows instead of adding new ones.
        String sha2 = 'fedcba9876543210fedcba9876543210fedcba98';
        Map<String, Object> next = event('Commit', 'Success', wi.Name, 'dev');
        next.put('commitSha', sha2);
        next.put('components', new List<Object>{ new Map<String, Object>{ 'type' => 'ApexClass', 'name' => 'Foo', 'action' => 'D' } });
        Assert.areEqual(200, postCallback(next).statusCode);
        Assert.areEqual(2, [SELECT COUNT() FROM CDO_Commit__c]);
        Assert.areEqual(2, [SELECT COUNT() FROM CDO_Component__c WHERE Work_Item__c = :wi.Id]);
        String fooKey = wi.Name + '|ApexClass:Foo';
        CDO_Component__c updated = [SELECT Action__c, Last_Commit_SHA__c FROM CDO_Component__c WHERE Work_Item_Key__c = :fooKey];
        Assert.areEqual('Delete', updated.Action__c);
        Assert.areEqual(sha2, updated.Last_Commit_SHA__c);

        Assert.areEqual(200, postCallback(next).statusCode, 'the same commit again updates it');
        Assert.areEqual(2, [SELECT COUNT() FROM CDO_Commit__c]);
        Assert.areEqual(200, postCallback(event('Commit', 'Running', wi.Name, 'dev')).statusCode);
        Map<String, Object> failed = event('Commit', 'Failed', wi.Name, 'dev');
        failed.put('message', 'Nothing to commit');
        Assert.areEqual(200, postCallback(failed).statusCode);
        Assert.areEqual(2, [SELECT COUNT() FROM CDO_Commit__c]);
    }

    @isTest
    static void pullRequestAndApprovalEvents() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        String prUrl = 'https://github.com/acme/sfdevops-sample/pull/7';
        Map<String, Object> pr = event('pull_request', 'Success', wi.Name, null);
        pr.put('pullRequestUrl', prUrl);
        pr.put('pullRequestNumber', 7);
        Assert.areEqual(200, postCallback(pr).statusCode);
        CDO_Work_Item__c inReview = workItem(wi.Id);
        Assert.areEqual(prUrl, inReview.Pull_Request_URL__c);
        Assert.isTrue(inReview.Pull_Request_Number__c == 7);
        Assert.areEqual('In_Review', inReview.Status__c);
        Map<String, Object> prFailed = event('PullRequest', 'Failed', wi.Name, null);
        prFailed.put('message', 'branch not found');
        Assert.areEqual(200, postCallback(prFailed).statusCode);

        Map<String, Object> approval = event('Approval', 'Success', wi.Name, 'int');
        approval.put('reviewState', 'APPROVED');
        approval.put('approver', 'octocat');
        approval.put('approvalMethod', 'review');
        approval.put('pullRequestUrl', prUrl);
        Assert.areEqual(200, postCallback(approval).statusCode);
        CDO_Approval__c a = [SELECT Decision__c, Method__c, Approver__c, Stage__c, Source_URL__c, Decided_On__c FROM CDO_Approval__c WHERE Work_Item__c = :wi.Id];
        Assert.areEqual('Approved', a.Decision__c);
        Assert.areEqual('Review', a.Method__c);
        Assert.areEqual('octocat', a.Approver__c);
        Assert.areEqual(d.stageInt.Id, a.Stage__c);
        Assert.areEqual(prUrl, a.Source_URL__c);
        Assert.isNotNull(a.Decided_On__c);
        CDO_Work_Item__c approved = workItem(wi.Id);
        Assert.isTrue(approved.Pull_Requests_Approved__c);
        Assert.areEqual('Approved', approved.Review_State__c);
        Assert.areEqual('Approved', approved.Status__c);

        Map<String, Object> changes = event('Approval', 'Success', wi.Name, 'int');
        changes.put('reviewState', 'changes_requested');
        changes.put('approvalMethod', 'Label');
        Assert.areEqual(200, postCallback(changes).statusCode);
        CDO_Work_Item__c rejected = workItem(wi.Id);
        Assert.areEqual('Changes_Requested', rejected.Review_State__c);
        Assert.isFalse(rejected.Pull_Requests_Approved__c);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Approval__c WHERE Decision__c = 'Rejected']);

        Map<String, Object> dismissed = event('Approval', 'Cancelled', wi.Name, null);
        dismissed.put('reviewState', 'dismissed');
        dismissed.put('approvalMethod', 'env');
        Assert.areEqual(200, postCallback(dismissed).statusCode);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Approval__c WHERE Decision__c = 'Removed' AND Method__c = 'Environment']);

        // A production reviewer's approval of a promotion is linked to it.
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageProd.Id, Status__c = 'Deploying');
        insert p;
        Map<String, Object> envApproval = promotionEvent(p.Id, 'Approval', 'Success');
        envApproval.put('pullRequestsApproved', true);
        envApproval.put('approvalMethod', 'Environment');
        Assert.areEqual(200, postCallback(envApproval).statusCode);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Approval__c WHERE Promotion__c = :p.Id AND Stage__c = :d.stageProd.Id]);
    }

    @isTest
    static void conflictCheckFlagsOverlapsAndClearsThem() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        CDO_Work_Item__c other = d.workItems[1];
        String path = 'force-app/main/default/classes/Foo.cls';
        insert new List<CDO_Component__c>{
            new CDO_Component__c(Name = 'ApexClass:Foo', Work_Item__c = wi.Id, Unique_ID__c = 'ApexClass:Foo', Work_Item_Key__c = wi.Name + '|ApexClass:Foo', Path__c = path),
            new CDO_Component__c(Name = 'ApexClass:Other', Work_Item__c = wi.Id, Unique_ID__c = 'ApexClass:Other', Work_Item_Key__c = wi.Name + '|ApexClass:Other'),
            new CDO_Component__c(Name = 'ApexClass:Foo', Work_Item__c = other.Id, Unique_ID__c = 'ApexClass:Foo', Work_Item_Key__c = other.Name + '|ApexClass:Foo', Path__c = path)
        };
        Map<String, Object> conflict = event('Conflict', 'Failed', wi.Name, 'qa');
        conflict.put('conflictPaths', path);
        conflict.put('components', new List<Object>{ new Map<String, Object>{ 'type' => 'ApexClass', 'name' => 'Foo' } });
        Assert.areEqual(200, postCallback(conflict).statusCode);
        String ownFoo = wi.Name + '|ApexClass:Foo';
        String ownOther = wi.Name + '|ApexClass:Other';
        String otherFoo = other.Name + '|ApexClass:Foo';
        Assert.isTrue([SELECT Has_Conflict__c FROM CDO_Component__c WHERE Work_Item_Key__c = :ownFoo].Has_Conflict__c);
        Assert.isFalse([SELECT Has_Conflict__c FROM CDO_Component__c WHERE Work_Item_Key__c = :ownOther].Has_Conflict__c);
        Assert.isTrue([SELECT Has_Conflict__c FROM CDO_Component__c WHERE Work_Item_Key__c = :otherFoo].Has_Conflict__c);
        Assert.areEqual(path, workItem(wi.Id).Conflict_Paths__c);
        Assert.areEqual('New', workItem(wi.Id).Status__c, 'a pre-check overlap does not block the work item');

        Assert.areEqual(200, postCallback(event('Conflict', 'Success', wi.Name, 'qa')).statusCode);
        Assert.isFalse([SELECT Has_Conflict__c FROM CDO_Component__c WHERE Work_Item_Key__c = :ownFoo].Has_Conflict__c);
        Assert.isNull(workItem(wi.Id).Conflict_Paths__c);

        Assert.areEqual(200, postCallback(event('Merge', 'Success', wi.Name, 'qa')).statusCode);
        Assert.areEqual('Merged', workItem(wi.Id).Merge_State__c);
    }

    @isTest
    static void releaseEventsWalkTheReleaseToReleased() {
        TestData d = loadData();
        CDO_Release__c rel = new CDO_Release__c(Name = 'R1', Project__c = d.project.Id, Status__c = 'Planned');
        insert rel;
        CDO_Work_Item__c wi = d.workItems[2];
        update new CDO_Work_Item__c(Id = wi.Id, Release__c = rel.Id, Current_Stage__c = d.stageStage.Id, Status__c = 'Deployed');

        Map<String, Object> assemble = event('Merge', 'Running', null, null);
        assemble.put('releaseId', rel.Id);
        Assert.areEqual(200, postCallback(assemble).statusCode);
        Assert.areEqual('Assembling', [SELECT Status__c FROM CDO_Release__c WHERE Id = :rel.Id].Status__c);
        assemble.put('status', 'Success');
        assemble.put('promotionBranch', 'release/R1');
        Assert.areEqual(200, postCallback(assemble).statusCode);
        CDO_Release__c ready = [SELECT Status__c, Release_Branch__c FROM CDO_Release__c WHERE Id = :rel.Id];
        Assert.areEqual('Ready', ready.Status__c);
        Assert.areEqual('release/R1', ready.Release_Branch__c);

        Map<String, Object> validate = event('Validation', 'Running', null, 'prod');
        validate.put('releaseId', rel.Id);
        validate.put('runUrl', RUN_URL);
        Assert.areEqual(200, postCallback(validate).statusCode);
        Assert.areEqual('Validating', [SELECT Status__c FROM CDO_Release__c WHERE Id = :rel.Id].Status__c);
        validate.put('status', 'Success');
        validate.put('deployId', '0Af000000000001AAA');
        Assert.areEqual(200, postCallback(validate).statusCode);
        CDO_Release__c validated = [SELECT Status__c, Validated_Deploy_Id__c, Workflow_Run_URL__c FROM CDO_Release__c WHERE Id = :rel.Id];
        Assert.areEqual('Ready', validated.Status__c);
        Assert.areEqual('0Af000000000001AAA', validated.Validated_Deploy_Id__c);
        Assert.isNull(environment(d.envProd.Id).Health_Status__c, 'validation leaves production health alone');

        Map<String, Object> quick = event('QuickDeploy', 'Running', null, null);
        quick.put('releaseId', rel.Id);
        quick.put('runUrl', RUN_URL);
        Assert.areEqual(200, postCallback(quick).statusCode);
        Assert.areEqual('Releasing', [SELECT Status__c FROM CDO_Release__c WHERE Id = :rel.Id].Status__c);
        quick.put('status', 'Success');
        quick.put('pullRequestUrl', 'https://github.com/acme/sfdevops-sample/releases/tag/v1.0.0');
        Assert.areEqual(200, postCallback(quick).statusCode);
        CDO_Release__c released = [SELECT Status__c, Tag__c, Release_URL__c, Released_On__c FROM CDO_Release__c WHERE Id = :rel.Id];
        Assert.areEqual('Released', released.Status__c);
        Assert.areEqual('v1.0.0', released.Tag__c);
        Assert.areEqual('https://github.com/acme/sfdevops-sample/releases/tag/v1.0.0', released.Release_URL__c);
        Assert.isNotNull(released.Released_On__c);
        Assert.areEqual(2, [SELECT COUNT() FROM CDO_Deployment__c WHERE Release__c = :rel.Id], 'a validation and the quick deploy in one run stay two rows');
        Assert.areEqual('Healthy', environment(d.envProd.Id).Health_Status__c);
        CDO_Work_Item__c done = workItem(wi.Id);
        Assert.areEqual('Done', done.Status__c);
        Assert.areEqual(d.stageProd.Id, done.Current_Stage__c);

        quick.put('status', 'Running');
        Assert.areEqual(200, postCallback(quick).statusCode);
        Assert.areEqual('Released', [SELECT Status__c FROM CDO_Release__c WHERE Id = :rel.Id].Status__c, 'a late event never un-releases');
        Map<String, Object> failedRelease = event('Release', 'Failed', null, 'prod');
        failedRelease.put('releaseId', rel.Id);
        Assert.areEqual(200, postCallback(failedRelease).statusCode);
        Map<String, Object> cancelledRelease = event('Release', 'Cancelled', null, 'prod');
        cancelledRelease.put('releaseId', rel.Id);
        Assert.areEqual(200, postCallback(cancelledRelease).statusCode);
    }

    @isTest
    static void dataDeployUpdatesTheDataSetButNotHealth() {
        TestData d = loadData();
        CDO_Data_Set__c ds = new CDO_Data_Set__c(Name = 'Accounts', Project__c = d.project.Id, Status__c = 'Ready');
        insert ds;
        Map<String, Object> data = event('Data', 'Running', null, 'qa');
        data.put('deploymentId', ds.Id);
        data.put('runUrl', RUN_URL);
        Assert.areEqual(200, postCallback(data).statusCode);
        Assert.areEqual('Deploying', [SELECT Status__c FROM CDO_Data_Set__c WHERE Id = :ds.Id].Status__c);
        data.put('status', 'Success');
        Assert.areEqual(200, postCallback(data).statusCode);
        CDO_Data_Set__c after = [SELECT Status__c, Last_Run_URL__c, Last_Deployed_On__c FROM CDO_Data_Set__c WHERE Id = :ds.Id];
        Assert.areEqual('Deployed', after.Status__c);
        Assert.areEqual(RUN_URL, after.Last_Run_URL__c);
        Assert.isNotNull(after.Last_Deployed_On__c);
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Deployment__c WHERE Event_Type__c = 'Data']);
        Assert.isNull(environment(d.envQa.Id).Health_Status__c);
        data.put('status', 'Failed');
        data.put('runUrl', RUN_URL_2);
        Assert.areEqual(200, postCallback(data).statusCode);
        Assert.areEqual('Failed', [SELECT Status__c FROM CDO_Data_Set__c WHERE Id = :ds.Id].Status__c);
    }

    @isTest
    static void callbackServiceHelpersNormaliseInput() {
        Assert.areEqual('Success', CDO_CallbackService.normalizeStatus('succeeded'));
        Assert.areEqual('Running', CDO_CallbackService.normalizeStatus('in_progress'));
        Assert.areEqual('Failed', CDO_CallbackService.normalizeStatus('FAILURE'));
        Assert.areEqual('Cancelled', CDO_CallbackService.normalizeStatus('canceled'));
        Assert.isNull(CDO_CallbackService.normalizeStatus(' '));
        Assert.areEqual('QuickDeploy', CDO_CallbackService.normalizeEventType('quick_deploy'));
        Assert.areEqual('PullRequest', CDO_CallbackService.normalizeEventType('PR'));
        Assert.areEqual('Validation', CDO_CallbackService.normalizeEventType('validate'));
        Assert.areEqual('Deploy', CDO_CallbackService.normalizeEventType('deployment'));
        Assert.isNull(CDO_CallbackService.normalizeEventType(null));
        Assert.areEqual('RunLocalTests', CDO_CallbackService.normalizeTestLevel('run-local-tests'));
        Assert.areEqual('Pending', CDO_CallbackService.normalizeReviewState('COMMENTED'));
        Assert.areEqual('Retrieve', CDO_CallbackService.normalizeAction('retrieved'));
        Assert.isNull(CDO_CallbackService.normalizeAction('renamed'));
        Assert.isNull(CDO_CallbackService.normalizeAction(null));
        Assert.areEqual('ESLint', CDO_CallbackService.normalizeTool('eslint'));
        Assert.isNull(CDO_CallbackService.normalizeTool('other'));
        Assert.areEqual('High', CDO_CallbackService.normalizeSeverity('major'));
        Assert.areEqual('Low', CDO_CallbackService.normalizeSeverity('minor'));
        Assert.areEqual('Info', CDO_CallbackService.normalizeSeverity('5'));
        Assert.isNull(CDO_CallbackService.normalizeSeverity('weird'));
        Assert.isNull(CDO_CallbackService.parseDatetime('not a date'));
        Assert.isNull(CDO_CallbackService.parseDatetime(null));
        Assert.isNull(CDO_CallbackService.toId(null, CDO_Promotion__c.SObjectType, 'promotionId'));
        Assert.areEqual('WI-0001|ApexClass:Foo', CDO_CallbackService.componentKey('WI-0001', ' ApexClass ', 'Foo '));
        try {
            CDO_CallbackService.apply(null);
            Assert.fail('a null request is refused');
        } catch (CDO_CallbackService.CallbackException e) {
            Assert.isTrue(e.getMessage().contains('empty'));
        }
    }

    // =====================================================================================================
    // CDO_MergeStatusResource / CDO_MergeStatusService
    // =====================================================================================================

    @isTest
    static void mergeStatusRecordsMergedAndRefusedMerges() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        CDO_Promotion__c p = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageQa.Id, Status__c = 'Deployed', Workflow_Run_URL__c = RUN_URL);
        insert p;
        insert CDOPromotionDispatcher.junctionRows(p.Id, new List<CDO_Work_Item__c>{ wi });

        RestResponse merged = postMergeStatus(new Map<String, Object>{
            'promotionId' => p.Id, 'merged' => true, 'mergeSha' => 'abcdef0123456789', 'targetBranch' => 'qa', 'environment' => 'qa'
        });
        Assert.areEqual(200, merged.statusCode, merged.responseBody.toString());
        CDO_Promotion__c afterMerge = promotion(p.Id);
        Assert.areEqual('abcdef0123456789', afterMerge.Merge_SHA__c);
        Assert.areEqual('Merged', workItem(wi.Id).Merge_State__c);
        Assert.areEqual(1, auditCount('MergeStatus.Merged'));

        RestResponse refused = postMergeStatus(new Map<String, Object>{
            'runUrl' => RUN_URL, 'merged' => false, 'reason' => 'target moved during the run', 'targetBranch' => 'qa'
        });
        Assert.areEqual(200, refused.statusCode, refused.responseBody.toString());
        CDO_Promotion__c afterRefusal = promotion(p.Id);
        Assert.areEqual('Deployed', afterRefusal.Status__c, 'the org was deployed, so the promotion stays Deployed');
        Assert.isTrue(afterRefusal.Message__c.contains('target moved during the run'), afterRefusal.Message__c);
        Assert.areEqual('Not_Merged', workItem(wi.Id).Merge_State__c);
        Assert.areEqual(1, auditCount('MergeStatus.NotMerged'));

        RestResponse byItem = postMergeStatus(new Map<String, Object>{ 'workItem' => wi.Name, 'environment' => 'qa', 'merged' => true });
        Assert.areEqual(200, byItem.statusCode);
        Assert.areEqual('Merged', workItem(wi.Id).Merge_State__c);
        RestResponse itemOnly = postMergeStatus(new Map<String, Object>{ 'workItem' => d.workItems[1].Name, 'merged' => false });
        Assert.areEqual(200, itemOnly.statusCode);

        Assert.areEqual(400, postRaw('merge-status', null).statusCode);
        Assert.areEqual(400, postRaw('merge-status', '{oops').statusCode);
        Assert.areEqual(400, postMergeStatus(new Map<String, Object>{ 'promotionId' => p.Id }).statusCode, 'merged is required');
        Assert.areEqual(400, postMergeStatus(new Map<String, Object>{ 'workItem' => 'WI-9999', 'merged' => true }).statusCode);
        Assert.areEqual(400, postMergeStatus(new Map<String, Object>{ 'promotionId' => 'bad', 'merged' => true }).statusCode);
        Assert.areEqual(400, postMergeStatus(new Map<String, Object>{ 'promotionId' => fakeId(CDO_Promotion__c.SObjectType), 'merged' => true }).statusCode);
        Assert.isTrue(auditCount('MergeStatusRejected') >= 5);
    }

    // =====================================================================================================
    // CDO_SourceMemberResource
    // =====================================================================================================

    @isTest
    static void sourceMembersAreStoredNewestFirst() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        RestResponse res = postSourceMembers(new Map<String, Object>{
            'workItem' => wi.Name,
            'requestId' => 'req-1',
            'sourceOrg' => 'dev',
            'status' => 'Success',
            'members' => new List<Object>{
                new Map<String, Object>{ 'type' => 'ApexClass', 'name' => 'Old', 'lastModifiedDate' => '2026-10-01T10:00:00.000Z', 'lastModifiedBy' => 'Dev', 'state' => 'Changed' },
                new Map<String, Object>{ 'type' => 'Layout', 'name' => 'NoDate' },
                new Map<String, Object>{ 'type' => 'ApexClass', 'name' => 'New', 'lastModifiedDate' => '2026-10-12T10:00:00.000Z', 'state' => 'Added' },
                new Map<String, Object>{ 'type' => 'ApexClass', 'name' => 'Alpha', 'lastModifiedDate' => '2026-10-12T10:00:00.000Z' }
            }
        });
        Assert.areEqual(200, res.statusCode, res.responseBody.toString());
        CDO_Work_Item__c after = workItem(wi.Id);
        Assert.areEqual('Received', after.Source_Changes_Status__c);
        Assert.isNotNull(after.Source_Changes_Received_On__c);
        List<Object> stored = (List<Object>) JSON.deserializeUntyped(after.Source_Changes_JSON__c);
        Assert.areEqual(4, stored.size());
        Assert.areEqual('Alpha', ((Map<String, Object>) stored[0]).get('name'));
        Assert.areEqual('New', ((Map<String, Object>) stored[1]).get('name'));
        Assert.areEqual('Old', ((Map<String, Object>) stored[2]).get('name'));
        Assert.areEqual('NoDate', ((Map<String, Object>) stored[3]).get('name'), 'undated members go last');
        Assert.areEqual(1, auditCount('SourceMembers.Received'));

        RestResponse failed = postSourceMembers(new Map<String, Object>{ 'workItemId' => wi.Id, 'status' => 'Failed', 'message' => 'auth failed' });
        Assert.areEqual(200, failed.statusCode);
        Assert.areEqual('Failed', workItem(wi.Id).Source_Changes_Status__c);
        Assert.areEqual(4, ((List<Object>) JSON.deserializeUntyped(workItem(wi.Id).Source_Changes_JSON__c)).size(), 'a failure keeps the last list');

        Assert.areEqual(400, postSourceMembers(new Map<String, Object>{ 'workItem' => 'WI-9999' }).statusCode);
        Assert.areEqual(400, postSourceMembers(new Map<String, Object>{ 'status' => 'Success' }).statusCode);
        Assert.areEqual(400, postRaw('source-members', null).statusCode);
        Assert.areEqual(400, postRaw('source-members', '[[').statusCode);
        Assert.areEqual(0, CDO_SourceMemberResource.newestFirst(null).size());
    }

    @isTest
    static void sourceMembersKeepTheNewestWhenTheListIsTooLong() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        List<Object> members = new List<Object>();
        String longName = 'M'.repeat(200);
        for (Integer i = 0; i < 700; i++) {
            members.add(new Map<String, Object>{
                'type' => 'CustomField',
                'name' => longName + i,
                'lastModifiedDate' => Datetime.newInstanceGmt(2026, 1, 1).addMinutes(i).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\''),
                'lastModifiedBy' => 'Developer'
            });
        }
        RestResponse res = postSourceMembers(new Map<String, Object>{ 'workItem' => wi.Name, 'status' => 'Success', 'members' => members });
        Assert.areEqual(200, res.statusCode, res.responseBody.toString());
        String stored = workItem(wi.Id).Source_Changes_JSON__c;
        Assert.isTrue(stored.length() <= CDO_SourceMemberResource.MAX_JSON_LENGTH);
        List<Object> kept = (List<Object>) JSON.deserializeUntyped(stored);
        Assert.isTrue(kept.size() < 700);
        Assert.areEqual(longName + 699, ((Map<String, Object>) kept[0]).get('name'), 'the newest member survives');
    }

    // =====================================================================================================
    // CDO_NotificationService
    // =====================================================================================================

    @isTest
    static void notificationsReachEverySubscribedWebhook() {
        loadData();
        List<CDO_Webhook__c> hooks = new List<CDO_Webhook__c>{
            new CDO_Webhook__c(Name = 'Generic', Named_Credential__c = 'Hook_A', Path__c = 'hooks/a', Events__c = 'Deploy;Promotion', Format__c = 'Generic_JSON', Active__c = true),
            new CDO_Webhook__c(Name = 'Webex', Named_Credential__c = 'Hook_B', Events__c = 'Deploy', Format__c = 'Webex', Active__c = true),
            new CDO_Webhook__c(Name = 'Slack', Named_Credential__c = 'Hook_C', Path__c = '/services/x', Events__c = 'Deploy', Format__c = 'Slack', Active__c = true),
            new CDO_Webhook__c(Name = 'Teams', Named_Credential__c = 'Hook_D', Path__c = '?key=1', Events__c = 'Deploy', Format__c = 'Teams', Active__c = true),
            new CDO_Webhook__c(Name = 'No credential', Events__c = 'Deploy', Format__c = 'Slack', Active__c = true),
            new CDO_Webhook__c(Name = 'Inactive', Named_Credential__c = 'Hook_E', Events__c = 'Deploy', Format__c = 'Slack', Active__c = false),
            new CDO_Webhook__c(Name = 'Commits only', Named_Credential__c = 'Hook_F', Events__c = 'Commit', Format__c = 'Slack', Active__c = true)
        };
        insert hooks;
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        Test.startTest();
        CDO_NotificationService.notify('Deploy', 'Deploy Success on QA', new Map<String, Object>{ 'runUrl' => RUN_URL });
        Integer queued = Limits.getQueueableJobs();
        CDO_NotificationService.notify('Release', 'nobody listens', null);
        CDO_NotificationService.notify(null, 'ignored', null);
        Assert.areEqual(queued, Limits.getQueueableJobs(), 'no job without a subscriber');
        Test.stopTest();
        Map<String, CDO_Webhook__c> byName = new Map<String, CDO_Webhook__c>();
        for (CDO_Webhook__c h : [SELECT Name, Last_Status__c, Last_Sent_On__c FROM CDO_Webhook__c]) {
            byName.put(h.Name, h);
        }
        for (String name : new List<String>{ 'Generic', 'Webex', 'Slack', 'Teams' }) {
            Assert.areEqual('200 OK', byName.get(name).Last_Status__c, name);
            Assert.isNotNull(byName.get(name).Last_Sent_On__c, name);
        }
        Assert.areEqual('Skipped: no Named Credential', byName.get('No credential').Last_Status__c);
        Assert.isNull(byName.get('Inactive').Last_Status__c);
        Assert.isNull(byName.get('Commits only').Last_Status__c);
    }

    @isTest
    static void notificationFormatsAndFailures() {
        String payload = JSON.serialize(new Map<String, Object>{ 'runUrl' => RUN_URL, 'workItem' => 'WI-0001' });
        Map<String, Object> webex = (Map<String, Object>) JSON.deserializeUntyped(CDO_NotificationService.formatBody('Webex', 'Deploy', 'Deployed', payload));
        Assert.isTrue(((String) webex.get('markdown')).contains('[View run](' + RUN_URL + ')'));
        Map<String, Object> slack = (Map<String, Object>) JSON.deserializeUntyped(CDO_NotificationService.formatBody('Slack', 'Deploy', 'Deployed', payload));
        Assert.isTrue(((String) slack.get('text')).contains('<' + RUN_URL + '|View run>'));
        Map<String, Object> teams = (Map<String, Object>) JSON.deserializeUntyped(CDO_NotificationService.formatBody('Teams', 'Deploy', null, null));
        Assert.isTrue(((String) teams.get('text')).contains('Deploy'));
        Map<String, Object> generic = (Map<String, Object>) JSON.deserializeUntyped(CDO_NotificationService.formatBody(null, 'Deploy', 'Deployed', payload));
        Assert.areEqual('Deploy', generic.get('event'));
        Assert.areEqual('WI-0001', ((Map<String, Object>) generic.get('payload')).get('workItem'));
        Assert.areEqual('', CDO_NotificationService.normalizePath(null));
        Assert.areEqual('/a', CDO_NotificationService.normalizePath('a'));

        insert new CDO_Webhook__c(Name = 'Broken', Named_Credential__c = 'Hook_X', Events__c = 'Commit', Format__c = 'Generic_JSON', Active__c = true);
        GitHubMock mock = new GitHubMock();
        mock.throwError = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        System.enqueueJob(new CDO_NotificationService.NotifyJob('Commit', 'Committed', null));
        Test.stopTest();
        Assert.isTrue([SELECT Last_Status__c FROM CDO_Webhook__c WHERE Name = 'Broken'].Last_Status__c.startsWith('Error:'));
    }

    // =====================================================================================================
    // CDO_WorkItemService
    // =====================================================================================================

    @isTest
    static void createWorkItemDefaultsProjectAndNoStage() {
        TestData d = loadData();
        Id wiId = CDO_WorkItemService.createWorkItem(new CDO_Work_Item__c(Subject__c = 'New thing'));
        CDO_Work_Item__c wi = [SELECT Project__c, Current_Stage__c, Status__c FROM CDO_Work_Item__c WHERE Id = :wiId];
        Assert.areEqual(d.project.Id, wi.Project__c);
        Assert.isNull(wi.Current_Stage__c);
        Assert.areEqual('New', wi.Status__c);
        Assert.areEqual(1, auditCount('WorkItemCreated'));
        for (CDO_Work_Item__c bad : new List<CDO_Work_Item__c>{ null, new CDO_Work_Item__c(), new CDO_Work_Item__c(Id = wiId, Subject__c = 'x') }) {
            try {
                CDO_WorkItemService.createWorkItem(bad);
                Assert.fail('refused');
            } catch (CDO_WorkItemService.WorkItemException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
        // With no default key, the only active project is the default.
        CDO_Settings__c s = CDO_Settings__c.getOrgDefaults();
        s.Default_Project_Key__c = null;
        update s;
        Assert.areEqual(d.project.Id, CDO_WorkItemService.defaultProjectId());
    }

    @isTest
    static void workItemRequestsDispatchTheContractInputs() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        update new CDO_Work_Item__c(Id = wi.Id, Pull_Request_Number__c = 7, Description__c = 'Why', Acceptance_Criteria__c = 'What');
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        Test.startTest();
        CDO_WorkItemService.requestCommit(wi.Id, '[{"type":"ApexClass","name":"Foo"},{"Metadata_Type__c":"ApexClass","Member_Name__c":"Foo"},{"type":"Layout"}]', null);
        String requestId = CDO_WorkItemService.requestListChanges(wi.Id, null);
        CDO_WorkItemService.openPullRequest(wi.Id);
        CDO_WorkItemService.requestValidation(wi.Id);
        Assert.areEqual('Requested', workItem(wi.Id).Source_Changes_Status__c);
        Test.stopTest();
        Assert.isNotNull(requestId);
        Map<String, Map<String, Object>> inputsByWorkflow = new Map<String, Map<String, Object>>();
        for (CDO_Audit_Event__c ev : [SELECT Details__c FROM CDO_Audit_Event__c WHERE Event_Type__c = 'WorkflowDispatched']) {
            Map<String, Object> details = (Map<String, Object>) JSON.deserializeUntyped(ev.Details__c);
            inputsByWorkflow.put((String) details.get('workflow'), (Map<String, Object>) details.get('inputs'));
        }
        Assert.areEqual(4, inputsByWorkflow.size());
        Map<String, Object> commitInputs = inputsByWorkflow.get(GitHubService.WF_COMMIT);
        Assert.areEqual(wi.Name, commitInputs.get('work_item'));
        Assert.areEqual(String.valueOf(wi.Id), commitInputs.get('work_item_id'));
        Assert.areEqual('dev', commitInputs.get('source_org'));
        Assert.areEqual('[{"type":"ApexClass","name":"Foo"}]', commitInputs.get('components'));
        Assert.areEqual(wi.Name + ': Sample change 1', commitInputs.get('commit_message'));
        Assert.areEqual('feature/' + wi.Name, commitInputs.get('feature_branch'));
        Assert.areEqual(requestId, inputsByWorkflow.get(GitHubService.WF_LIST_CHANGES).get('request_id'));
        Assert.areEqual('feature/' + wi.Name, inputsByWorkflow.get(GitHubService.WF_OPEN_PR).get('feature_branch'));
        Assert.isTrue(((String) inputsByWorkflow.get(GitHubService.WF_OPEN_PR).get('body')).contains('Acceptance criteria'));
        Assert.areEqual('7', inputsByWorkflow.get(GitHubService.WF_PR_VALIDATION).get('pr_number'));
        Assert.areEqual(1, auditCount('CommitRequested'));
        Assert.areEqual(1, auditCount('ValidationRequested'));
    }

    @isTest
    static void workItemRequestsFailFastWithAReason() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        List<String> badComponents = new List<String>{ null, 'not json', '{"type":"ApexClass"}', '[]', '[1, {"name":"x"}]' };
        for (String bad : badComponents) {
            try {
                CDO_WorkItemService.requestCommit(wi.Id, bad, 'msg');
                Assert.fail('refused: ' + bad);
            } catch (CDO_WorkItemService.WorkItemException e) {
                Assert.isTrue(e.getMessage().toLowerCase().contains('component'), e.getMessage());
            }
        }
        try {
            CDO_WorkItemService.requestValidation(wi.Id);
            Assert.fail('no pull request yet');
        } catch (CDO_WorkItemService.WorkItemException e) {
            Assert.isTrue(e.getMessage().contains('pull request'));
        }
        try {
            CDO_WorkItemService.getWorkItem(null);
            Assert.fail('id required');
        } catch (CDO_WorkItemService.WorkItemException e) {
            Assert.isNotNull(e.getMessage());
        }
        try {
            CDO_WorkItemService.getWorkItem(fakeId(CDO_Work_Item__c.SObjectType));
            Assert.fail('not found');
        } catch (CDO_WorkItemService.WorkItemException e) {
            Assert.isTrue(e.getMessage().contains('not found'));
        }
        CDO_Settings__c s = CDO_Settings__c.getOrgDefaults();
        s.Dispatch_Enabled__c = false;
        update s;
        try {
            CDO_WorkItemService.requestCommit(wi.Id, '[{"type":"ApexClass","name":"Foo"}]', 'msg');
            Assert.fail('dispatch is off');
        } catch (CDO_WorkItemService.WorkItemException e) {
            Assert.isTrue(e.getMessage().contains('Dispatch Enabled'), e.getMessage());
        }
        try {
            CDO_WorkItemService.requestListChanges(wi.Id, 'dev');
            Assert.fail('dispatch is off');
        } catch (CDO_WorkItemService.WorkItemException e) {
            Assert.areNotEqual('Requested', workItem(wi.Id).Source_Changes_Status__c, 'nothing is marked requested when dispatch is off');
        }
        update new CDO_Work_Item__c(Id = wi.Id, Status__c = 'Done');
        try {
            CDO_WorkItemService.openPullRequest(wi.Id);
            Assert.fail('closed');
        } catch (CDO_WorkItemService.WorkItemException e) {
            Assert.isTrue(e.getMessage().contains('Done'));
        }
    }

    @isTest
    static void nextStageFollowsOrderAndStopsAtProduction() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        Assert.areEqual(d.stageInt.Id, CDO_WorkItemService.nextStage(wi.Id).Id, 'no stage yet: the entry stage');
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = d.stageInt.Id);
        Assert.areEqual(d.stageQa.Id, CDO_WorkItemService.nextStage(wi.Id).Id);
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = d.stageStage.Id);
        Assert.areEqual(d.stageProd.Id, CDO_WorkItemService.nextStage(wi.Id).Id);
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = d.stageProd.Id);
        Assert.isNull(CDO_WorkItemService.nextStage(wi.Id), 'null at production');
        update new CDO_Work_Item__c(Id = wi.Id, Project__c = null);
        Assert.isNull(CDO_WorkItemService.nextStage(wi.Id));
        Assert.isNull(CDO_WorkItemService.nextStageFrom(new List<CDO_Stage__c>(), null));
        List<CDO_Stage__c> unflagged = new List<CDO_Stage__c>{ new CDO_Stage__c(Name = 'A'), new CDO_Stage__c(Name = 'B') };
        Assert.areEqual('A', CDO_WorkItemService.nextStageFrom(unflagged, null).Name);
        Assert.areEqual('A', CDO_WorkItemService.nextStageFrom(new List<CDO_Stage__c>{ new CDO_Stage__c(Name = 'A', Is_Production__c = true) }, null).Name);
        Assert.isNull(CDO_WorkItemService.nextStageFrom(d.stages, fakeId(CDO_Stage__c.SObjectType)));
    }

    @isTest
    static void markBlockedAndFeatureBranch() {
        TestData d = loadData();
        CDO_Work_Item__c open = d.workItems[0];
        CDO_Work_Item__c done = d.workItems[1];
        update new CDO_Work_Item__c(Id = done.Id, Status__c = 'Done');
        CDO_WorkItemService.markBlocked(new Set<Id>{ open.Id, done.Id }, 'x'.repeat(40000));
        CDO_WorkItemService.markBlocked(null, 'ignored');
        CDO_Work_Item__c blocked = workItem(open.Id);
        Assert.areEqual('Blocked', blocked.Status__c);
        Assert.areEqual(32768, blocked.Blocked_Reason__c.length());
        Assert.areEqual('Done', workItem(done.Id).Status__c, 'closed work items are left alone');
        Assert.areEqual(1, auditCount('WorkItemBlocked'));
        Assert.areEqual('feature/custom', CDO_WorkItemService.featureBranch(new CDO_Work_Item__c(Feature_Branch__c = ' feature/custom ')));
        Assert.areEqual('feature/' + open.Name, CDO_WorkItemService.featureBranch(open));
        Assert.isNull(CDO_WorkItemService.featureBranch(null));
        Assert.isNull(CDO_WorkItemService.featureBranch(new CDO_Work_Item__c()));
    }

    // =====================================================================================================
    // CDOPromotionDispatcher
    // =====================================================================================================

    @isTest
    static void requestPromotionWritesJunctionRowsAndAudit() {
        TestData d = loadData();
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        List<Id> ids = new List<Id>{ d.workItems[0].Id, d.workItems[1].Id, d.workItems[2].Id };
        Id promotionId = CDOPromotionDispatcher.requestPromotion(ids, d.stageInt.Id, null, false);
        CDO_Promotion__c p = promotion(promotionId);
        Assert.areEqual('Draft', p.Status__c);
        Assert.areEqual('Forward', p.Direction__c);
        Assert.areEqual(UserInfo.getUserId(), p.Requested_By__c);
        Assert.isTrue(p.Allow_Destructive__c);
        Assert.isFalse(p.Check_Only__c);
        Assert.areEqual(3, p.Promoted_Work_Items__r.size(), 'one junction row per work item');
        Set<String> keys = new Set<String>();
        for (CDO_Promoted_Work_Item__c row : p.Promoted_Work_Items__r) {
            keys.add(row.Unique_Key__c);
            Assert.areEqual('Pending', row.Status__c);
        }
        for (Id i : ids) {
            Assert.isTrue(keys.contains(promotionId + ':' + i));
        }
        Assert.areEqual(1, auditCount('PromotionRequested'));
        try {
            CDOPromotionDispatcher.requestPromotion(new List<Id>{ d.workItems[1].Id }, d.stageQa.Id, null, true);
            Assert.fail('a second open promotion is refused');
        } catch (CDOPromotionDispatcher.PromotionException e) {
            Assert.isTrue(e.getMessage().contains('already has an open promotion'), e.getMessage());
        }
        CDOPromotionDispatcher.dispatchPromotion(promotionId);
        CDO_Promotion__c dispatched = promotion(promotionId);
        Assert.areEqual('Dispatched', dispatched.Status__c, 'Dispatched, never Deploying, until a callback says so');
        Assert.isNotNull(dispatched.Dispatched_On__c);
        Assert.areEqual(1, auditCount('PromotionDispatched'));
        try {
            CDOPromotionDispatcher.dispatchPromotion(promotionId);
            Assert.fail('cannot dispatch twice');
        } catch (CDOPromotionDispatcher.PromotionException e) {
            Assert.isTrue(e.getMessage().contains('Dispatched'));
        }
    }

    @isTest
    static void queueDispatchesOneAtATimePerStageOldestFirst() {
        TestData d = new TestData('sample');
        List<CDO_Work_Item__c> extra = new List<CDO_Work_Item__c>{ new CDO_Work_Item__c(Subject__c = 'Extra', Project__c = d.project.Id) };
        insert extra;
        CDO_Work_Item__c a = d.workItems[0];
        CDO_Work_Item__c b = d.workItems[1];
        CDO_Work_Item__c c = d.workItems[2];
        placeAt(a, d.stageInt);
        placeAt(b, d.stageInt);
        placeAt(extra[0], d.stageInt);
        placeAt(c, d.stageQa);
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        Id p1 = CDOPromotionDispatcher.requestPromotion(new List<Id>{ a.Id }, d.stageQa.Id, null, true);
        Id p2 = CDOPromotionDispatcher.requestPromotion(new List<Id>{ b.Id }, d.stageQa.Id, null, true);
        Id p4 = CDOPromotionDispatcher.requestPromotion(new List<Id>{ extra[0].Id }, d.stageQa.Id, null, true);
        Id p3 = CDOPromotionDispatcher.requestPromotion(new List<Id>{ c.Id }, d.stageStage.Id, null, true);
        Assert.areEqual('Dispatched', promotion(p1).Status__c);
        Assert.areEqual('Queued', promotion(p2).Status__c);
        Assert.areEqual('Queued', promotion(p4).Status__c);
        Assert.areEqual('Dispatched', promotion(p3).Status__c, 'another stage has its own queue');
        Assert.areEqual(1, [SELECT COUNT() FROM CDO_Promotion__c WHERE Target_Stage__c = :d.stageQa.Id AND Status__c IN ('Dispatched', 'Deploying')]);

        // p4 is older than p2, so it goes first.
        Test.setCreatedDate(p4, System.now().addDays(-1));
        update new CDO_Promotion__c(Id = p1, Status__c = 'Deployed');
        CDOPromotionDispatcher.onPromotionFinished(p1);
        Assert.areEqual('Dispatched', promotion(p4).Status__c, 'oldest queued first');
        Assert.areEqual('Queued', promotion(p2).Status__c);
        CDOPromotionDispatcher.dispatchNext(d.stageQa.Id);
        Assert.areEqual('Queued', promotion(p2).Status__c, 'still one in flight');
        CDOPromotionDispatcher.onPromotionFinished(null);
        CDOPromotionDispatcher.dispatchNext(null);
    }

    @isTest
    static void promotionDispatchSendsTheSfPromotionInputs() {
        TestData d = loadData();
        CDO_Work_Item__c a = d.workItems[0];
        CDO_Work_Item__c b = d.workItems[1];
        update new List<CDO_Work_Item__c>{
            new CDO_Work_Item__c(Id = a.Id, Current_Stage__c = d.stageInt.Id, Test_Level_Override__c = 'NoTestRun', Specified_Tests__c = 'FooTest, BarTest'),
            new CDO_Work_Item__c(Id = b.Id, Current_Stage__c = d.stageInt.Id, Test_Level_Override__c = 'RunLocalTests', Specified_Tests__c = 'FooTest', Feature_Branch__c = 'feature/custom-b')
        };
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        Test.startTest();
        Id promotionId = CDOPromotionDispatcher.requestPromotion(new List<Id>{ b.Id, a.Id }, d.stageQa.Id, new Map<String, String>{ 'allowDestructive' => 'false' }, true);
        Test.stopTest();
        CDO_Promotion__c p = promotion(promotionId);
        Assert.areEqual('Dispatched', p.Status__c, 'a 204 alone never makes a promotion Deploying');
        Assert.areEqual('RunLocalTests', p.Test_Level__c, 'the strictest work item override');
        Assert.areEqual('FooTest,BarTest', p.Specified_Tests__c);
        Assert.areEqual(d.stageInt.Id, p.Source_Stage__c);
        CDO_Audit_Event__c ev = [SELECT Details__c FROM CDO_Audit_Event__c WHERE Event_Type__c = 'WorkflowDispatched'];
        Map<String, Object> details = (Map<String, Object>) JSON.deserializeUntyped(ev.Details__c);
        Assert.areEqual(GitHubService.WF_PROMOTION, details.get('workflow'));
        Map<String, Object> inputs = (Map<String, Object>) details.get('inputs');
        Assert.areEqual(String.valueOf(promotionId), inputs.get('promotion_id'));
        Assert.areEqual(a.Name + ',' + b.Name, inputs.get('work_items'));
        Assert.areEqual('feature/' + a.Name + ',feature/custom-b', inputs.get('feature_refs'));
        Assert.areEqual('qa', inputs.get('target_env'));
        Assert.areEqual('RunLocalTests', inputs.get('test_level'));
        Assert.areEqual('FooTest,BarTest', inputs.get('specified_tests'));
        Assert.areEqual('false', inputs.get('check_only'));
        Assert.areEqual('false', inputs.get('allow_destructive'));
        for (Object v : inputs.values()) {
            Assert.isTrue(v instanceof String);
        }
    }

    @isTest
    static void requestPromotionValidatesItsInput() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        CDO_Project__c otherProject = new CDO_Project__c(Name = 'Other', Key__c = 'other', Active__c = true);
        insert otherProject;
        CDO_Stage__c otherStage = new CDO_Stage__c(Name = 'OTHER', Key__c = 'other:int', Project__c = otherProject.Id, Order__c = 1, Pipeline_Key__c = 'int');
        insert otherStage;
        CDO_Work_Item__c cancelled = d.workItems[1];
        update new CDO_Work_Item__c(Id = cancelled.Id, Status__c = 'Cancelled');
        update new CDO_Work_Item__c(Id = wi.Id, Current_Stage__c = d.stageQa.Id);
        Map<String, List<Object>> cases = new Map<String, List<Object>>{
            'Select at least one' => new List<Object>{ new List<Id>(), d.stageQa.Id, null },
            'target stage is required' => new List<Object>{ new List<Id>{ wi.Id }, null, null },
            'was not found' => new List<Object>{ new List<Id>{ wi.Id }, fakeId(CDO_Stage__c.SObjectType), null },
            'different project' => new List<Object>{ new List<Id>{ wi.Id }, otherStage.Id, null },
            'is cancelled' => new List<Object>{ new List<Id>{ cancelled.Id }, d.stageQa.Id, null },
            'already in' => new List<Object>{ new List<Id>{ wi.Id }, d.stageQa.Id, null },
            'Unknown test level' => new List<Object>{ new List<Id>{ wi.Id }, d.stageStage.Id, new Map<String, String>{ 'testLevel' => 'Everything' } },
            'not visible' => new List<Object>{ new List<Id>{ fakeId(CDO_Work_Item__c.SObjectType) }, d.stageQa.Id, null }
        };
        for (String expected : cases.keySet()) {
            List<Object> args = cases.get(expected);
            try {
                CDOPromotionDispatcher.requestPromotion((List<Id>) args[0], (Id) args[1], (Map<String, String>) args[2], false);
                Assert.fail('expected: ' + expected);
            } catch (CDOPromotionDispatcher.PromotionException e) {
                Assert.isTrue(e.getMessage().contains(expected), expected + ' / ' + e.getMessage());
            }
        }
        // Moving down the chain is a Back promotion; options are honoured.
        Id back = CDOPromotionDispatcher.requestPromotion(new List<Id>{ wi.Id }, d.stageInt.Id, new Map<String, String>{ 'checkOnly' => 'yes', 'specifiedTests' => 'ATest BTest', 'allowDestructive' => 'maybe' }, false);
        CDO_Promotion__c p = promotion(back);
        Assert.areEqual('Back', p.Direction__c);
        Assert.isTrue(p.Check_Only__c);
        Assert.isTrue(p.Allow_Destructive__c);
        Assert.areEqual('ATest,BTest', p.Specified_Tests__c);
        try {
            CDOPromotionDispatcher.dispatchPromotion(null);
            Assert.fail('id required');
        } catch (CDOPromotionDispatcher.PromotionException e) {
            Assert.isNotNull(e.getMessage());
        }
        try {
            CDOPromotionDispatcher.dispatchPromotion(fakeId(CDO_Promotion__c.SObjectType));
            Assert.fail('not found');
        } catch (CDOPromotionDispatcher.PromotionException e) {
            Assert.isTrue(e.getMessage().contains('not found'));
        }
    }

    @isTest
    static void aPromotionWithoutWorkItemsIsNeverDispatched() {
        TestData d = loadData();
        CDO_Promotion__c empty = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageQa.Id, Status__c = 'Queued');
        CDO_Promotion__c draft = new CDO_Promotion__c(Project__c = d.project.Id, Target_Stage__c = d.stageQa.Id, Status__c = 'Draft');
        insert new List<CDO_Promotion__c>{ empty, draft };
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        CDOPromotionDispatcher.dispatchNext(d.stageQa.Id);
        CDO_Promotion__c after = promotion(empty.Id);
        Assert.areEqual('Failed', after.Status__c);
        Assert.isTrue(after.Message__c.contains('no work items'));
        Assert.areEqual(1, auditCount('PromotionRejected'));
        try {
            CDOPromotionDispatcher.dispatchPromotion(draft.Id);
            Assert.fail('a promotion with no junction rows cannot be dispatched');
        } catch (CDOPromotionDispatcher.PromotionException e) {
            Assert.isTrue(e.getMessage().contains('no work items'));
        }
    }

    @isTest
    static void theQueueHoldsWhileDispatchIsOff() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        placeAt(wi, d.stageInt);
        CDO_Settings__c s = CDO_Settings__c.getOrgDefaults();
        s.Dispatch_Enabled__c = false;
        update s;
        Id promotionId = CDOPromotionDispatcher.requestPromotion(new List<Id>{ wi.Id }, d.stageQa.Id, null, true);
        Assert.areEqual('Queued', promotion(promotionId).Status__c);
        Assert.areEqual(1, auditCount('PromotionQueueHeld'));
    }

    @isTest
    static void deferredDispatchesThatCannotBeQueuedGoBackToQueued() {
        TestData d = loadData();
        CDO_Work_Item__c wi = d.workItems[0];
        placeAt(wi, d.stageInt);
        Id promotionId = CDOPromotionDispatcher.requestPromotion(new List<Id>{ wi.Id }, d.stageQa.Id, null, false);
        update new CDO_Promotion__c(Id = promotionId, Status__c = 'Queued');
        Test.setMock(HttpCalloutMock.class, new GitHubMock());
        // Use up the transaction's queueable allowance so the deferred job cannot be enqueued.
        Integer limitJobs = Limits.getLimitQueueableJobs();
        for (Integer i = Limits.getQueueableJobs(); i < limitJobs; i++) {
            System.enqueueJob(new GitHubService.DispatchJob(new List<GitHubService.DispatchRequest>()));
        }
        CDOPromotionDispatcher.beginDeferral();
        CDOPromotionDispatcher.dispatchNext(d.stageQa.Id);
        Assert.areEqual('Dispatched', promotion(promotionId).Status__c);
        CDOPromotionDispatcher.endDeferral();
        Assert.areEqual('Queued', promotion(promotionId).Status__c, 'nothing could be queued, so it waits for the next sweep');
        Assert.areEqual(1, auditCount('PromotionDispatchDeferred'));
        // The non-deferred path behaves the same way.
        CDOPromotionDispatcher.dispatchNext(d.stageQa.Id);
        Assert.areEqual('Queued', promotion(promotionId).Status__c);
        Assert.areEqual(2, auditCount('PromotionDispatchDeferred'));
        Assert.isNull(GitHubService.enqueue(null));
    }
}
