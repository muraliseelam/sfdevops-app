/**
 * The promotion queue. A GitHub concurrency group is not a queue (one running, one pending, and a
 * third arrival evicts the pending one), so promotions queue here and leave one at a time.
 *
 * - One promotion in flight (Dispatched or Deploying) per target stage.
 * - Oldest Queued first: ORDER BY CreatedDate, Id.
 * - Every promotion is written with its CDO_Promoted_Work_Item__c junction rows. A promotion
 *   without them can never resolve, so one is failed rather than dispatched.
 * - Dispatched only means GitHub was asked. Deploying is set by the Running callback, never here.
 */
public with sharing class CDOPromotionDispatcher {

    public class PromotionException extends Exception {}

    public static final Set<String> IN_FLIGHT_STATUSES = new Set<String>{ 'Dispatched', 'Deploying' };
    public static final Set<String> OPEN_STATUSES = new Set<String>{ 'Draft', 'Queued', 'Dispatched', 'Deploying' };
    public static final Set<String> TERMINAL_STATUSES = new Set<String>{ 'Deployed', 'Failed', 'Conflict', 'Cancelled' };
    public static final List<String> TEST_LEVELS = new List<String>{
        'NoTestRun', 'RunSpecifiedTests', 'RunLocalTests', 'RunAllTestsInOrg'
    };

    /** Dispatches collected while deferring; null when not deferring. */
    private static List<GitHubService.DispatchRequest> deferred;
    private static Integer deferralDepth = 0;

    /**
     * Creates a promotion (Queued, or Draft when dispatchNow is false) with one junction row per work
     * item and an audit event, then lets the queue move when dispatchNow is true.
     * options keys: testLevel, specifiedTests, checkOnly, allowDestructive, direction.
     */
    public static Id requestPromotion(List<Id> workItemIds, Id targetStageId, Map<String, String> options, Boolean dispatchNow) {
        Set<Id> ids = new Set<Id>();
        if (workItemIds != null) {
            for (Id i : workItemIds) {
                if (i != null) {
                    ids.add(i);
                }
            }
        }
        if (ids.isEmpty()) {
            throw new PromotionException('Select at least one work item to promote.');
        }
        if (targetStageId == null) {
            throw new PromotionException('A target stage is required.');
        }
        Map<String, String> opts = options == null ? new Map<String, String>() : options;

        List<CDO_Stage__c> stageRows = [
            SELECT Id, Name, Project__c, Order__c, Branch__c, Pipeline_Key__c, Is_Production__c
            FROM CDO_Stage__c
            WHERE Id = :targetStageId
        ];
        if (stageRows.isEmpty()) {
            throw new PromotionException('Stage ' + targetStageId + ' was not found.');
        }
        CDO_Stage__c target = stageRows[0];

        List<CDO_Work_Item__c> items = [
            SELECT Id, Name, Project__c, Status__c, Current_Stage__c, Current_Stage__r.Order__c,
                Feature_Branch__c, Test_Level_Override__c, Specified_Tests__c
            FROM CDO_Work_Item__c
            WHERE Id IN :ids
            ORDER BY Name
        ];
        if (items.size() != ids.size()) {
            throw new PromotionException('One or more work items were not found or are not visible to you.');
        }
        Id sourceStageId = items[0].Current_Stage__c;
        Decimal sourceOrder = items[0].Current_Stage__c == null ? null : items[0].Current_Stage__r.Order__c;
        Boolean sameSource = true;
        for (CDO_Work_Item__c wi : items) {
            if (wi.Project__c != null && wi.Project__c != target.Project__c) {
                throw new PromotionException(wi.Name + ' belongs to a different project than stage ' + target.Name + '.');
            }
            if (wi.Status__c == 'Cancelled') {
                throw new PromotionException(wi.Name + ' is cancelled.');
            }
            if (wi.Current_Stage__c == target.Id) {
                throw new PromotionException(wi.Name + ' is already in ' + target.Name + '.');
            }
            if (wi.Current_Stage__c != sourceStageId) {
                sameSource = false;
            }
        }
        new SystemStore().assertNoOpenPromotion(ids);

        String direction = pick(opts.get('direction'), new List<String>{ 'Forward', 'Back' });
        if (direction == null) {
            direction = (sameSource && sourceOrder != null && target.Order__c != null && target.Order__c < sourceOrder)
                ? 'Back'
                : 'Forward';
        }
        CDO_Promotion__c p = new CDO_Promotion__c(
            Project__c = target.Project__c,
            Source_Stage__c = sameSource ? sourceStageId : null,
            Target_Stage__c = target.Id,
            Direction__c = direction,
            Status__c = dispatchNow == true ? 'Queued' : 'Draft',
            Target_Branch__c = target.Branch__c,
            Check_Only__c = toBoolean(opts.get('checkOnly'), false),
            Allow_Destructive__c = toBoolean(opts.get('allowDestructive'), true),
            Test_Level__c = resolveTestLevel(opts.get('testLevel'), items),
            Specified_Tests__c = resolveSpecifiedTests(opts.get('specifiedTests'), items),
            Requested_By__c = UserInfo.getUserId()
        );
        insert p;
        insert junctionRows(p.Id, items);

        List<String> keys = new List<String>();
        for (CDO_Work_Item__c wi : items) {
            keys.add(wi.Name);
        }
        CDO_Audit.log(
            'PromotionRequested',
            'Promotion of ' + String.join(keys, ', ') + ' to ' + target.Name + ' requested (' + p.Status__c + ')',
            JSON.serializePretty(opts),
            new Map<String, Id>{ 'promotion' => p.Id }
        );
        if (dispatchNow == true) {
            dispatchNext(target.Id);
        }
        return p.Id;
    }

    /** Draft -> Queued, then dispatchNext for its target stage. */
    public static void dispatchPromotion(Id promotionId) {
        if (promotionId == null) {
            throw new PromotionException('A promotion id is required.');
        }
        List<CDO_Promotion__c> rows = [
            SELECT Id, Name, Status__c, Target_Stage__c, (SELECT Id FROM Promoted_Work_Items__r LIMIT 1)
            FROM CDO_Promotion__c
            WHERE Id = :promotionId
        ];
        if (rows.isEmpty()) {
            throw new PromotionException('Promotion ' + promotionId + ' was not found.');
        }
        CDO_Promotion__c p = rows[0];
        if (p.Promoted_Work_Items__r.isEmpty()) {
            throw new PromotionException(p.Name + ' carries no work items, so it cannot be dispatched.');
        }
        if (p.Status__c == 'Draft') {
            p.Status__c = 'Queued';
            update p;
            CDO_Audit.log('PromotionQueued', p.Name + ' queued', null, new Map<String, Id>{ 'promotion' => p.Id });
        } else if (p.Status__c != 'Queued') {
            throw new PromotionException(p.Name + ' is ' + p.Status__c + ' and cannot be dispatched again.');
        }
        dispatchNext(p.Target_Stage__c);
    }

    /** Dispatches the oldest Queued promotion for the stage, unless one is already in flight there. */
    public static void dispatchNext(Id targetStageId) {
        if (targetStageId == null) {
            return;
        }
        new SystemStore().dispatchNext(targetStageId);
    }

    /** A promotion reached a terminal status: free its stage and dispatch the next queued one. */
    public static void onPromotionFinished(Id promotionId) {
        if (promotionId == null) {
            return;
        }
        new SystemStore().finished(promotionId);
    }

    /**
     * Collect dispatches instead of enqueuing one job per stage. Used inside asynchronous jobs, which
     * may enqueue only one child job: endDeferral() sends everything collected in one DispatchJob.
     */
    public static void beginDeferral() {
        deferralDepth++;
        if (deferred == null) {
            deferred = new List<GitHubService.DispatchRequest>();
        }
    }

    public static void endDeferral() {
        if (deferralDepth > 0) {
            deferralDepth--;
        }
        if (deferralDepth > 0) {
            return;
        }
        List<GitHubService.DispatchRequest> collected = deferred;
        deferred = null;
        if (collected == null || collected.isEmpty()) {
            return;
        }
        Id jobId = GitHubService.enqueue(new GitHubService.DispatchJob(collected));
        if (jobId == null) {
            new SystemStore().requeue(collected);
        }
    }

    /** The sf-promotion.yml inputs (docs/CONTRACTS.md section 1). Every value is a string. */
    public static Map<String, String> promotionInputs(CDO_Promotion__c p, List<CDO_Promoted_Work_Item__c> rows, CDO_Stage__c target) {
        List<String> keys = new List<String>();
        List<String> refs = new List<String>();
        Map<String, CDO_Work_Item__c> byName = new Map<String, CDO_Work_Item__c>();
        for (CDO_Promoted_Work_Item__c row : rows) {
            if (row.Work_Item__r != null && row.Work_Item__r.Name != null) {
                byName.put(row.Work_Item__r.Name, row.Work_Item__r);
            }
        }
        List<String> names = new List<String>(byName.keySet());
        names.sort();
        for (String name : names) {
            keys.add(name);
            refs.add(CDO_WorkItemService.featureBranch(byName.get(name)));
        }
        return new Map<String, String>{
            'promotion_id' => String.valueOf(p.Id),
            'work_items' => String.join(keys, ','),
            'feature_refs' => String.join(refs, ','),
            'target_env' => target == null || target.Pipeline_Key__c == null ? '' : target.Pipeline_Key__c,
            'test_level' => p.Test_Level__c == null ? '' : p.Test_Level__c,
            'specified_tests' => p.Specified_Tests__c == null ? '' : p.Specified_Tests__c,
            'check_only' => p.Check_Only__c == true ? 'true' : 'false',
            'allow_destructive' => p.Allow_Destructive__c == false ? 'false' : 'true'
        };
    }

    /** Junction rows for a new promotion. Unique_Key__c = promotionId + ':' + workItemId. */
    public static List<CDO_Promoted_Work_Item__c> junctionRows(Id promotionId, List<CDO_Work_Item__c> items) {
        List<CDO_Promoted_Work_Item__c> rows = new List<CDO_Promoted_Work_Item__c>();
        for (CDO_Work_Item__c wi : items) {
            rows.add(
                new CDO_Promoted_Work_Item__c(
                    Promotion__c = promotionId,
                    Work_Item__c = wi.Id,
                    Status__c = 'Pending',
                    Unique_Key__c = junctionKey(promotionId, wi.Id)
                )
            );
        }
        return rows;
    }

    public static String junctionKey(Id promotionId, Id workItemId) {
        return String.valueOf(promotionId) + ':' + String.valueOf(workItemId);
    }

    // ---- Option resolution -----------------------------------------------------------------------

    /** Explicit option, else the strictest work item override, else blank (the pipeline config decides). */
    private static String resolveTestLevel(String option, List<CDO_Work_Item__c> items) {
        if (String.isNotBlank(option)) {
            String level = pick(option, TEST_LEVELS);
            if (level == null) {
                throw new PromotionException('Unknown test level "' + option + '". Use one of ' + String.join(TEST_LEVELS, ', ') + '.');
            }
            return level;
        }
        Integer strictest = -1;
        for (CDO_Work_Item__c wi : items) {
            Integer rank = TEST_LEVELS.indexOf(wi.Test_Level_Override__c);
            if (rank > strictest) {
                strictest = rank;
            }
        }
        return strictest < 0 ? null : TEST_LEVELS[strictest];
    }

    /** Explicit option, else the union of the work items' Specified_Tests__c, cut at a whole name to fit 255. */
    private static String resolveSpecifiedTests(String option, List<CDO_Work_Item__c> items) {
        List<String> names = new List<String>();
        Set<String> seen = new Set<String>();
        List<String> sources = new List<String>();
        if (String.isNotBlank(option)) {
            sources.add(option);
        } else {
            for (CDO_Work_Item__c wi : items) {
                if (String.isNotBlank(wi.Specified_Tests__c)) {
                    sources.add(wi.Specified_Tests__c);
                }
            }
        }
        for (String source : sources) {
            for (String part : source.split('[,\\s]+')) {
                String name = part.trim();
                if (String.isNotBlank(name) && seen.add(name.toLowerCase())) {
                    names.add(name);
                }
            }
        }
        String joined = '';
        for (String name : names) {
            String candidate = joined == '' ? name : joined + ',' + name;
            if (candidate.length() > 255) {
                break;
            }
            joined = candidate;
        }
        return joined == '' ? null : joined;
    }

    private static Boolean toBoolean(String value, Boolean defaultValue) {
        if (String.isBlank(value)) {
            return defaultValue;
        }
        String v = value.trim().toLowerCase();
        if (v == 'true' || v == 'yes' || v == '1') {
            return true;
        }
        if (v == 'false' || v == 'no' || v == '0') {
            return false;
        }
        return defaultValue;
    }

    private static String pick(String raw, List<String> allowed) {
        if (String.isBlank(raw)) {
            return null;
        }
        String k = raw.replaceAll('[^A-Za-z0-9]', '').toLowerCase();
        for (String a : allowed) {
            if (a.replaceAll('[^A-Za-z0-9]', '').toLowerCase() == k) {
                return a;
            }
        }
        return null;
    }

    /**
     * without sharing, deliberately and narrowly: the queue is an invariant across every user's
     * promotions. "One in flight per stage" and "no second open promotion for a work item" are only
     * true if they are checked against all promotions, including ones the caller cannot see, and the
     * next dispatch may be triggered by the pipeline integration user's callback.
     */
    private without sharing class SystemStore {

        public void assertNoOpenPromotion(Set<Id> workItemIds) {
            List<CDO_Promoted_Work_Item__c> open = [
                SELECT Work_Item__r.Name, Promotion__r.Name, Promotion__r.Status__c
                FROM CDO_Promoted_Work_Item__c
                WHERE Work_Item__c IN :workItemIds AND Promotion__r.Status__c IN :OPEN_STATUSES
                LIMIT 1
            ];
            if (!open.isEmpty()) {
                CDO_Promoted_Work_Item__c row = open[0];
                throw new PromotionException(
                    row.Work_Item__r.Name + ' already has an open promotion: ' + row.Promotion__r.Name +
                    ' (' + row.Promotion__r.Status__c + ').'
                );
            }
        }

        public void dispatchNext(Id stageId) {
            String configError = GitHubService.configurationError();
            if (configError != null) {
                CDO_Audit.log('PromotionQueueHeld', 'Promotion queue held: ' + configError, null, null);
                return;
            }
            // Lock the stage row: two transactions finishing promotions for the same stage at the same
            // moment must not both see "nothing in flight" and both dispatch.
            List<CDO_Stage__c> locked = [
                SELECT Id, Name, Pipeline_Key__c FROM CDO_Stage__c WHERE Id = :stageId FOR UPDATE
            ];
            if (locked.isEmpty()) {
                return;
            }
            Integer inFlight = [
                SELECT COUNT() FROM CDO_Promotion__c
                WHERE Target_Stage__c = :stageId AND Status__c IN :IN_FLIGHT_STATUSES
            ];
            if (inFlight > 0) {
                return;
            }
            List<CDO_Promotion__c> broken = new List<CDO_Promotion__c>();
            CDO_Promotion__c next;
            for (CDO_Promotion__c p : [
                SELECT Id, Name, Status__c, Check_Only__c, Allow_Destructive__c, Test_Level__c, Specified_Tests__c,
                    Target_Stage__c,
                    (SELECT Id, Work_Item__c, Work_Item__r.Name, Work_Item__r.Feature_Branch__c FROM Promoted_Work_Items__r)
                FROM CDO_Promotion__c
                WHERE Target_Stage__c = :stageId AND Status__c = 'Queued'
                ORDER BY CreatedDate ASC, Id ASC
                LIMIT 20
            ]) {
                if (p.Promoted_Work_Items__r.isEmpty()) {
                    broken.add(p);
                    continue;
                }
                next = p;
                break;
            }
            if (!broken.isEmpty()) {
                List<CDO_Audit_Event__c> events = new List<CDO_Audit_Event__c>();
                for (CDO_Promotion__c p : broken) {
                    p.Status__c = 'Failed';
                    p.Completed_On__c = System.now();
                    p.Message__c = 'Not dispatched: the promotion carries no work items (no CDO_Promoted_Work_Item__c rows).';
                    events.add(CDO_Audit.build('PromotionRejected', p.Name + ' carries no work items and was not dispatched.', null, new Map<String, Id>{ 'promotion' => p.Id }));
                }
                update broken;
                CDO_Audit.log(events);
            }
            if (next == null) {
                return;
            }
            GitHubService.DispatchRequest request = new GitHubService.DispatchRequest(
                GitHubService.WF_PROMOTION,
                GitHubService.defaultRef(),
                promotionInputs(next, next.Promoted_Work_Items__r, locked[0]),
                next.Id
            );
            if (deferred != null) {
                deferred.add(request);
            } else {
                Id jobId = GitHubService.enqueue(new GitHubService.DispatchJob(new List<GitHubService.DispatchRequest>{ request }));
                if (jobId == null) {
                    CDO_Audit.log(
                        'PromotionDispatchDeferred',
                        next.Name + ' stays Queued: no asynchronous job could be started in this transaction.',
                        null,
                        new Map<String, Id>{ 'promotion' => next.Id }
                    );
                    return;
                }
            }
            update new CDO_Promotion__c(Id = next.Id, Status__c = 'Dispatched', Dispatched_On__c = System.now(), Message__c = null);
            CDO_Audit.log(
                'PromotionDispatched',
                next.Name + ' dispatched to ' + locked[0].Name + ' (' + GitHubService.WF_PROMOTION + ')',
                JSON.serializePretty(request.inputs),
                new Map<String, Id>{ 'promotion' => next.Id }
            );
        }

        public void finished(Id promotionId) {
            List<CDO_Promotion__c> rows = [SELECT Id, Target_Stage__c FROM CDO_Promotion__c WHERE Id = :promotionId];
            if (rows.isEmpty() || rows[0].Target_Stage__c == null) {
                return;
            }
            dispatchNext(rows[0].Target_Stage__c);
        }

        /** Deferred dispatches that could not be enqueued go back to Queued. */
        public void requeue(List<GitHubService.DispatchRequest> requests) {
            Set<Id> ids = new Set<Id>();
            for (GitHubService.DispatchRequest r : requests) {
                if (r.recordId != null && r.recordId.getSObjectType() == CDO_Promotion__c.SObjectType) {
                    ids.add(r.recordId);
                }
            }
            List<CDO_Promotion__c> rows = [SELECT Id, Name FROM CDO_Promotion__c WHERE Id IN :ids AND Status__c = 'Dispatched'];
            List<CDO_Audit_Event__c> events = new List<CDO_Audit_Event__c>();
            for (CDO_Promotion__c p : rows) {
                p.Status__c = 'Queued';
                p.Dispatched_On__c = null;
                events.add(
                    CDO_Audit.build(
                        'PromotionDispatchDeferred',
                        p.Name + ' stays Queued: no asynchronous job could be started in this transaction.',
                        null,
                        new Map<String, Id>{ 'promotion' => p.Id }
                    )
                );
            }
            update rows;
            CDO_Audit.log(events);
        }
    }
}
