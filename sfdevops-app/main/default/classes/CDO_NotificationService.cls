/**
 * Outbound notifications to every active CDO_Webhook__c subscribed to an event type.
 *
 * notify() is asynchronous (a Queueable that calls out) and never throws into its caller: a
 * notification is worth less than the change it reports. Each webhook gets a POST to
 * callout:<Named_Credential__c><Path__c> in its Format__c (Generic_JSON, Webex, Slack or Teams), and
 * Last_Status__c / Last_Sent_On__c record the result.
 */
public with sharing class CDO_NotificationService {

    public static final String SOURCE_NAME = 'SF DevOps';
    /** Callouts per job: 10 webhooks at 10 s each stay inside the 120 s callout budget. */
    public static final Integer MAX_WEBHOOKS = 10;
    public static final Integer TIMEOUT_MS = 10000;

    /** eventType is a CDO_Webhook__c.Events__c value: Commit, Validation, Deploy, Promotion, Release, Conflict, Approval. */
    public static void notify(String eventType, String summary, Map<String, Object> payload) {
        try {
            if (String.isBlank(eventType) || !new WebhookStore().hasSubscribersFor(eventType)) {
                return;
            }
            // Inside an asynchronous job only one child job may be queued, and a dispatch needs that
            // slot more than a notification does.
            Integer free = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();
            Boolean async = System.isQueueable() || System.isBatch() || System.isFuture() || System.isScheduled();
            if (free <= 0 || (async && free <= 1)) {
                System.debug(LoggingLevel.INFO, 'CDO notification skipped (no job slot): ' + summary);
                return;
            }
            GitHubService.enqueue(new NotifyJob(eventType, summary, payload == null ? null : JSON.serialize(payload)));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'CDO notification skipped: ' + e.getMessage());
        }
    }

    /** The request body for a webhook format. Public so the formats can be tested and previewed. */
    public static String formatBody(String format, String eventType, String summary, String payloadJson) {
        String text = String.isBlank(summary) ? eventType : summary;
        Map<String, Object> payload = new Map<String, Object>();
        if (String.isNotBlank(payloadJson)) {
            Object parsed = JSON.deserializeUntyped(payloadJson);
            if (parsed instanceof Map<String, Object>) {
                payload = (Map<String, Object>) parsed;
            }
        }
        String runUrl = payload.get('runUrl') == null ? null : String.valueOf(payload.get('runUrl'));
        if (format == 'Webex') {
            return JSON.serialize(new Map<String, Object>{
                'markdown' => '**' + SOURCE_NAME + ' ' + eventType + '**: ' + text +
                    (String.isBlank(runUrl) ? '' : ' [View run](' + runUrl + ')')
            });
        }
        if (format == 'Slack') {
            return JSON.serialize(new Map<String, Object>{
                'text' => '*' + SOURCE_NAME + ' ' + eventType + '*: ' + text +
                    (String.isBlank(runUrl) ? '' : ' <' + runUrl + '|View run>')
            });
        }
        if (format == 'Teams') {
            return JSON.serialize(new Map<String, Object>{
                'text' => '**' + SOURCE_NAME + ' ' + eventType + '**: ' + text +
                    (String.isBlank(runUrl) ? '' : ' [View run](' + runUrl + ')')
            });
        }
        return JSON.serialize(new Map<String, Object>{
            'source' => SOURCE_NAME,
            'event' => eventType,
            'summary' => text,
            'payload' => payload,
            'sentOn' => System.now()
        });
    }

    /** Callout path: blank stays blank, otherwise it starts with "/" or "?". */
    public static String normalizePath(String path) {
        if (String.isBlank(path)) {
            return '';
        }
        String p = path.trim();
        return p.startsWith('/') || p.startsWith('?') ? p : '/' + p;
    }

    /**
     * without sharing, deliberately and narrowly: webhooks are org-level configuration, and an event
     * raised by the pipeline integration user must still reach every subscribed webhook.
     */
    private without sharing class WebhookStore {
        public Boolean hasSubscribersFor(String eventType) {
            return ![
                SELECT Id FROM CDO_Webhook__c WHERE Active__c = true AND Events__c INCLUDES (:eventType) LIMIT 1
            ].isEmpty();
        }
    }

    /** without sharing for the same reason as WebhookStore: it reads webhooks and records their last status. */
    public without sharing class NotifyJob implements Queueable, Database.AllowsCallouts {
        public String eventType;
        public String summary;
        public String payloadJson;

        public NotifyJob(String eventType, String summary, String payloadJson) {
            this.eventType = eventType;
            this.summary = summary;
            this.payloadJson = payloadJson;
        }

        public void execute(QueueableContext context) {
            send();
        }

        public void send() {
            List<CDO_Webhook__c> hooks = [
                SELECT Id, Name, Named_Credential__c, Path__c, Format__c
                FROM CDO_Webhook__c
                WHERE Active__c = true AND Events__c INCLUDES (:eventType)
                ORDER BY Name
                LIMIT :MAX_WEBHOOKS
            ];
            for (CDO_Webhook__c hook : hooks) {
                hook.Last_Sent_On__c = System.now();
                if (String.isBlank(hook.Named_Credential__c)) {
                    hook.Last_Status__c = 'Skipped: no Named Credential';
                    continue;
                }
                try {
                    HttpRequest req = new HttpRequest();
                    req.setEndpoint('callout:' + hook.Named_Credential__c.trim() + normalizePath(hook.Path__c));
                    req.setMethod('POST');
                    req.setHeader('Content-Type', 'application/json');
                    req.setTimeout(TIMEOUT_MS);
                    req.setBody(formatBody(hook.Format__c, eventType, summary, payloadJson));
                    HttpResponse res = new Http().send(req);
                    hook.Last_Status__c = fit((res.getStatusCode() + ' ' + (res.getStatus() == null ? '' : res.getStatus())).trim());
                } catch (Exception e) {
                    hook.Last_Status__c = fit('Error: ' + e.getMessage());
                }
            }
            if (!hooks.isEmpty()) {
                Database.update(hooks, false);
            }
        }

        private String fit(String value) {
            return value.length() > 80 ? value.abbreviate(80) : value;
        }
    }
}
