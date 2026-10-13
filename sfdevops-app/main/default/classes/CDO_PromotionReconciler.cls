/**
 * Resolves finished promotions and sweeps the ones whose callback never arrived.
 *
 * resolvePromotedWorkItems reads the CDO_Promoted_Work_Item__c junction. A promotion without junction
 * rows cannot say what it carried, so it returns early, and says so in the audit trail, instead of
 * silently doing nothing.
 *
 * inherited sharing: called by CDO_CallbackService, which the REST resources reach through a
 * system-context hop, and by ReconcileJob, which runs without sharing.
 */
public inherited sharing class CDO_PromotionReconciler {

    public static final Integer DEFAULT_TIMEOUT_MINUTES = 90;
    public static final Integer MAX_PROMOTIONS_PER_SWEEP = 10;
    public static final Integer MAX_RUN_LOOKUPS = 5;
    public static final String NEVER_STARTED_MESSAGE = 'Workflow never started: no run URL was ever reported';
    public static final String RUNS_PATH = '/actions/runs?event=workflow_dispatch&per_page=50';

    /**
     * Marks every junction row Deployed and moves each work item to the target stage
     * (Merge_State__c Merged, Status__c Deployed, or Done at production).
     */
    public static void resolvePromotedWorkItems(Id promotionId) {
        if (promotionId == null) {
            return;
        }
        List<CDO_Promotion__c> promotions = [
            SELECT Id, Name, Direction__c, Target_Stage__c, Target_Stage__r.Name, Target_Stage__r.Order__c,
                Target_Stage__r.Is_Production__c
            FROM CDO_Promotion__c
            WHERE Id = :promotionId
        ];
        if (promotions.isEmpty()) {
            return;
        }
        CDO_Promotion__c p = promotions[0];
        List<CDO_Promoted_Work_Item__c> rows = [
            SELECT Id, Status__c, Work_Item__c FROM CDO_Promoted_Work_Item__c WHERE Promotion__c = :promotionId
        ];
        if (rows.isEmpty()) {
            CDO_Audit.log(
                'PromotionUnresolved',
                p.Name + ' carries no promoted work items, so no work item was moved.',
                'Every promotion entry point must write CDO_Promoted_Work_Item__c rows. Without them the ' +
                'promotion cannot say what it carried and no work item reaches ' +
                (p.Target_Stage__r == null ? 'the target stage' : p.Target_Stage__r.Name) + '.',
                new Map<String, Id>{ 'promotion' => p.Id }
            );
            return;
        }
        Set<Id> workItemIds = new Set<Id>();
        for (CDO_Promoted_Work_Item__c row : rows) {
            row.Status__c = 'Deployed';
            if (row.Work_Item__c != null) {
                workItemIds.add(row.Work_Item__c);
            }
        }
        update rows;

        Boolean production = p.Target_Stage__r != null && p.Target_Stage__r.Is_Production__c == true;
        Decimal targetOrder = p.Target_Stage__r == null ? null : p.Target_Stage__r.Order__c;
        Boolean forward = p.Direction__c != 'Back';
        List<CDO_Work_Item__c> moved = new List<CDO_Work_Item__c>();
        List<String> skipped = new List<String>();
        for (CDO_Work_Item__c wi : [
            SELECT Id, Name, Status__c, Current_Stage__c, Current_Stage__r.Order__c
            FROM CDO_Work_Item__c
            WHERE Id IN :workItemIds
        ]) {
            if (wi.Status__c == 'Cancelled') {
                skipped.add(wi.Name + ' (cancelled)');
                continue;
            }
            Decimal currentOrder = wi.Current_Stage__c == null ? null : wi.Current_Stage__r.Order__c;
            if (forward && currentOrder != null && targetOrder != null && currentOrder > targetOrder) {
                // A late result for a lower stage never drags a work item back down the chain.
                skipped.add(wi.Name + ' (already further along)');
                continue;
            }
            moved.add(
                new CDO_Work_Item__c(
                    Id = wi.Id,
                    Current_Stage__c = p.Target_Stage__c,
                    Merge_State__c = 'Merged',
                    Status__c = production ? 'Done' : 'Deployed',
                    Blocked_Reason__c = null
                )
            );
        }
        update moved;
        CDO_Audit.log(
            'PromotionResolved',
            p.Name + ': ' + moved.size() + ' work item' + (moved.size() == 1 ? '' : 's') + ' moved to ' +
            (p.Target_Stage__r == null ? 'the target stage' : p.Target_Stage__r.Name) + '.',
            skipped.isEmpty() ? null : 'Not moved: ' + String.join(skipped, ', '),
            new Map<String, Id>{ 'promotion' => p.Id }
        );
    }

    /** A workflow run as GitHub reports it. */
    public class RunInfo {
        public String id;
        public String name;
        public String displayTitle;
        public String htmlUrl;
        public String status;
        public String conclusion;
    }

    public static List<RunInfo> parseRuns(String body) {
        List<RunInfo> runs = new List<RunInfo>();
        if (String.isBlank(body)) {
            return runs;
        }
        Object parsed = JSON.deserializeUntyped(body);
        if (!(parsed instanceof Map<String, Object>)) {
            return runs;
        }
        Object workflowRuns = ((Map<String, Object>) parsed).get('workflow_runs');
        if (!(workflowRuns instanceof List<Object>)) {
            return runs;
        }
        for (Object item : (List<Object>) workflowRuns) {
            RunInfo run = parseRun(item);
            if (run != null) {
                runs.add(run);
            }
        }
        return runs;
    }

    public static RunInfo parseRun(Object item) {
        if (!(item instanceof Map<String, Object>)) {
            return null;
        }
        Map<String, Object> m = (Map<String, Object>) item;
        RunInfo run = new RunInfo();
        run.id = m.get('id') == null ? null : String.valueOf(m.get('id'));
        run.name = (String) m.get('name');
        run.displayTitle = (String) m.get('display_title');
        run.htmlUrl = (String) m.get('html_url');
        run.status = (String) m.get('status');
        run.conclusion = (String) m.get('conclusion');
        return run;
    }

    /** The newest run that is this promotion's: same run URL, or a run name naming the promotion (Name or Id). */
    public static RunInfo findRun(List<RunInfo> runs, CDO_Promotion__c p) {
        if (runs == null || p == null) {
            return null;
        }
        if (String.isNotBlank(p.Workflow_Run_URL__c)) {
            for (RunInfo run : runs) {
                if (run.htmlUrl != null && run.htmlUrl.equalsIgnoreCase(p.Workflow_Run_URL__c.trim())) {
                    return run;
                }
            }
        }
        List<String> tokens = new List<String>();
        if (String.isNotBlank(p.Name)) {
            tokens.add(p.Name);
        }
        tokens.add(String.valueOf(p.Id));
        tokens.add(String.valueOf(p.Id).left(15));
        for (RunInfo run : runs) {
            for (String token : tokens) {
                if (containsToken(run.displayTitle, token) || containsToken(run.name, token)) {
                    return run;
                }
            }
        }
        return null;
    }

    /** True when text contains token not followed by another digit or letter (so PRM-00001 never matches PRM-000012). */
    public static Boolean containsToken(String text, String token) {
        if (String.isBlank(text) || String.isBlank(token)) {
            return false;
        }
        Integer idx = text.indexOf(token);
        while (idx >= 0) {
            Integer after = idx + token.length();
            if (after >= text.length() || !text.substring(after, after + 1).isAlphanumeric()) {
                return true;
            }
            idx = text.indexOf(token, idx + 1);
        }
        return false;
    }

    /** success -> Success, cancelled -> Cancelled, anything else concluded -> Failed. */
    public static String outcome(String conclusion) {
        if (conclusion == 'success') {
            return 'Success';
        }
        if (conclusion == 'cancelled') {
            return 'Cancelled';
        }
        return 'Failed';
    }

    public static String runIdFromUrl(String runUrl) {
        if (String.isBlank(runUrl) || !runUrl.contains('/actions/runs/')) {
            return null;
        }
        String id = runUrl.substringAfter('/actions/runs/').substringBefore('/').substringBefore('?');
        return id.isNumeric() ? id : null;
    }

    public static Integer timeoutMinutes() {
        Decimal configured = GitHubService.settings().Promotion_Timeout_Minutes__c;
        return configured == null || configured <= 0 ? DEFAULT_TIMEOUT_MINUTES : configured.intValue();
    }

    /** Runs the sweep now, asynchronously. Returns the job id, or null when no job could be queued. */
    public static Id sweepNow() {
        return GitHubService.enqueue(new SweepJob());
    }

    /**
     * The queueable form of the sweep. Salesforce refuses to enqueue a class that also implements
     * Schedulable ("Queueable cannot be implemented with other system interfaces"), so the scheduled
     * ReconcileJob hands over to this job, and System.enqueueJob takes this one.
     */
    public without sharing class SweepJob implements Queueable, Database.AllowsCallouts {
        public void execute(QueueableContext context) {
            new ReconcileJob().run();
        }
    }

    /**
     * The stuck-run sweep. Schedule it (for example hourly):
     *   System.schedule('CDO promotion reconciler', '0 0 * * * ?', new CDO_PromotionReconciler.ReconcileJob());
     * or run it once now with CDO_PromotionReconciler.sweepNow().
     *
     * Promotions Dispatched or Deploying for longer than CDO_Settings__c.Promotion_Timeout_Minutes__c
     * (default 90) are looked up on GitHub. A concluded run applies its outcome, exactly as its lost
     * callback would have. A promotion that never reported a run URL and has no run on GitHub is
     * failed with "Workflow never started". Afterwards every idle stage queue is nudged.
     *
     * without sharing, deliberately: the sweep is a system job that must see every stuck promotion,
     * whoever requested it.
     */
    public without sharing class ReconcileJob implements Schedulable, Queueable, Database.AllowsCallouts {

        /** Scheduled Apex cannot call out, so the scheduled run hands over to SweepJob. */
        public void execute(SchedulableContext context) {
            GitHubService.enqueue(new SweepJob());
        }

        /** Part of the contract's interface list. The platform will not enqueue this class; use SweepJob. */
        public void execute(QueueableContext context) {
            run();
        }

        public void run() {
            Datetime cutoff = System.now().addMinutes(-timeoutMinutes());
            List<CDO_Promotion__c> stuck = [
                SELECT Id, Name, Status__c, Check_Only__c, Workflow_Run_URL__c, Dispatched_On__c, CreatedDate,
                    Target_Stage__c
                FROM CDO_Promotion__c
                WHERE Status__c IN :CDOPromotionDispatcher.IN_FLIGHT_STATUSES
                    AND ((Dispatched_On__c != null AND Dispatched_On__c < :cutoff)
                        OR (Dispatched_On__c = null AND CreatedDate < :cutoff))
                ORDER BY CreatedDate ASC, Id ASC
                LIMIT :MAX_PROMOTIONS_PER_SWEEP
            ];

            // ---- Callouts only ----
            Boolean listed = false;
            String listError;
            List<RunInfo> runs = new List<RunInfo>();
            Map<Id, RunInfo> fetched = new Map<Id, RunInfo>();
            if (!stuck.isEmpty()) {
                HttpResponse res = GitHubService.send('GET', RUNS_PATH, null);
                if (res.getStatusCode() == 200) {
                    try {
                        runs = parseRuns(res.getBody());
                        listed = true;
                    } catch (Exception e) {
                        listError = 'unreadable response: ' + e.getMessage();
                    }
                } else {
                    String body = res.getBody() == null ? '' : res.getBody();
                    listError = 'HTTP ' + res.getStatusCode() + ' ' + (body.length() > 300 ? body.abbreviate(300) : body);
                }
                if (listed) {
                    Integer lookups = 0;
                    for (CDO_Promotion__c p : stuck) {
                        if (lookups >= MAX_RUN_LOOKUPS || String.isBlank(p.Workflow_Run_URL__c) || findRun(runs, p) != null) {
                            continue;
                        }
                        // A known run older than the first page of results: ask for it by id.
                        String runId = runIdFromUrl(p.Workflow_Run_URL__c);
                        if (runId == null) {
                            continue;
                        }
                        lookups++;
                        HttpResponse one = GitHubService.send('GET', '/actions/runs/' + runId, null);
                        if (one.getStatusCode() == 200) {
                            try {
                                RunInfo run = parseRun(JSON.deserializeUntyped(one.getBody()));
                                if (run != null) {
                                    fetched.put(p.Id, run);
                                }
                            } catch (Exception e) {
                                System.debug(LoggingLevel.WARN, 'Unreadable run ' + runId + ': ' + e.getMessage());
                            }
                        }
                    }
                }
            }

            // ---- DML only from here on ----
            String previousSource = CDO_Audit.getSource();
            CDO_Audit.setSource(CDO_Audit.SOURCE_SYSTEM);
            CDOPromotionDispatcher.beginDeferral();
            try {
                if (!stuck.isEmpty() && !listed) {
                    CDO_Audit.log(
                        'ReconcileFailed',
                        'Could not list workflow runs, so ' + stuck.size() + ' stuck promotion(s) were left as they are.',
                        listError,
                        null
                    );
                } else {
                    for (CDO_Promotion__c p : stuck) {
                        reconcile(p, fetched.containsKey(p.Id) ? fetched.get(p.Id) : findRun(runs, p));
                    }
                }
                kickIdleQueues();
            } finally {
                CDOPromotionDispatcher.endDeferral();
                CDO_Audit.setSource(previousSource);
            }
        }

        private void reconcile(CDO_Promotion__c p, RunInfo run) {
            Savepoint sp = Database.setSavepoint();
            try {
                if (run == null) {
                    if (String.isBlank(p.Workflow_Run_URL__c)) {
                        neverStarted(p);
                    } else {
                        CDO_Audit.log(
                            'ReconcileRunNotFound',
                            p.Name + ': its run could not be found on GitHub; left ' + p.Status__c + '.',
                            p.Workflow_Run_URL__c,
                            new Map<String, Id>{ 'promotion' => p.Id }
                        );
                    }
                } else if (run.status != 'completed') {
                    CDO_Audit.log(
                        'ReconcileStillRunning',
                        p.Name + ': run ' + run.id + ' is still ' + run.status + '; left ' + p.Status__c + '.',
                        run.htmlUrl,
                        new Map<String, Id>{ 'promotion' => p.Id }
                    );
                } else {
                    CDO_CallbackResource.CallbackRequest req = new CDO_CallbackResource.CallbackRequest();
                    req.promotionId = String.valueOf(p.Id);
                    req.status = outcome(run.conclusion);
                    req.runUrl = run.htmlUrl;
                    req.eventType = p.Check_Only__c == true ? 'Validation' : 'Deploy';
                    req.checkOnly = p.Check_Only__c;
                    req.message = 'Reconciled from GitHub: run ' + run.id + ' concluded "' + run.conclusion +
                        '" but its callback never reached the hub.';
                    CDO_CallbackService.apply(req);
                }
            } catch (Exception e) {
                Database.rollback(sp);
                CDO_Audit.log(
                    'ReconcileError',
                    p.Name + ' could not be reconciled: ' + e.getMessage(),
                    e.getStackTraceString(),
                    new Map<String, Id>{ 'promotion' => p.Id }
                );
            }
        }

        private void neverStarted(CDO_Promotion__c p) {
            update new CDO_Promotion__c(
                Id = p.Id,
                Status__c = 'Failed',
                Message__c = NEVER_STARTED_MESSAGE,
                Completed_On__c = System.now()
            );
            List<CDO_Promoted_Work_Item__c> rows = [
                SELECT Id FROM CDO_Promoted_Work_Item__c WHERE Promotion__c = :p.Id AND Status__c = 'Pending'
            ];
            for (CDO_Promoted_Work_Item__c row : rows) {
                row.Status__c = 'Failed';
            }
            update rows;
            CDO_Audit.log(
                'PromotionNeverStarted',
                p.Name + ': ' + NEVER_STARTED_MESSAGE + '.',
                'Status ' + p.Status__c + ' for longer than ' + timeoutMinutes() +
                ' minutes and no matching workflow_dispatch run on GitHub. Nothing was deployed.',
                new Map<String, Id>{ 'promotion' => p.Id }
            );
            CDOPromotionDispatcher.onPromotionFinished(p.Id);
        }

        /** Stages with queued promotions and nothing in flight get their next dispatch. */
        private void kickIdleQueues() {
            if (GitHubService.configurationError() != null) {
                return;
            }
            for (AggregateResult ar : [
                SELECT Target_Stage__c FROM CDO_Promotion__c
                WHERE Status__c = 'Queued' AND Target_Stage__c != null
                GROUP BY Target_Stage__c
                LIMIT 20
            ]) {
                CDOPromotionDispatcher.dispatchNext((Id) ar.get('Target_Stage__c'));
            }
        }
    }
}
