/**
 * Append-only history (CDO_Audit_Event__c). Everything of consequence writes one event.
 *
 * Bulk-safe: events are collected and inserted together. Between hold() and release() nothing is
 * written until the outermost release(), so a callback or a loop costs one insert, not one per event.
 *
 * inherited sharing: an audit event is written in the sharing context of whoever caused it, which
 * includes the REST callbacks' system-context hop.
 */
public inherited sharing class CDO_Audit {

    public static final String SOURCE_HUB = 'Hub';
    public static final String SOURCE_GITHUB = 'GitHub';
    public static final String SOURCE_SYSTEM = 'System';

    private static final Integer EVENT_TYPE_MAX = 80;
    private static final Integer SUMMARY_MAX = 255;
    private static final Integer ACTOR_MAX = 255;
    private static final Integer DETAILS_MAX = 131072;
    private static final Integer URL_MAX = 255;

    private static String source;
    private static Integer holdDepth = 0;
    private static List<CDO_Audit_Event__c> pending = new List<CDO_Audit_Event__c>();

    /** Source__c for events written from now on (Hub when unset). Pass null to reset. */
    public static void setSource(String value) {
        source = String.isBlank(value) ? null : value;
    }

    public static String getSource() {
        return source;
    }

    /** Buffer events until the matching release(). Calls nest. */
    public static void hold() {
        holdDepth++;
    }

    /** Ends one hold(); the outermost release() writes everything buffered. */
    public static void release() {
        if (holdDepth > 0) {
            holdDepth--;
        }
        if (holdDepth == 0) {
            flush();
        }
    }

    /** Writes every buffered event now. */
    public static void flush() {
        if (pending.isEmpty()) {
            return;
        }
        List<CDO_Audit_Event__c> batch = pending;
        pending = new List<CDO_Audit_Event__c>();
        write(batch);
    }

    /** refs keys: workItem, promotion, deployment, release. Each Id is filed by its own type. */
    public static void log(String eventType, String summary, String details, Map<String, Id> refs) {
        log(build(eventType, summary, details, refs));
    }

    public static void log(CDO_Audit_Event__c ev) {
        if (ev == null) {
            return;
        }
        log(new List<CDO_Audit_Event__c>{ ev });
    }

    public static void log(List<CDO_Audit_Event__c> events) {
        if (events == null || events.isEmpty()) {
            return;
        }
        for (CDO_Audit_Event__c ev : events) {
            if (ev != null) {
                stamp(ev);
                pending.add(ev);
            }
        }
        if (holdDepth == 0) {
            flush();
        }
    }

    /** Builds (does not write) an event, for callers that add Run_URL__c or collect several. */
    public static CDO_Audit_Event__c build(String eventType, String summary, String details, Map<String, Id> refs) {
        CDO_Audit_Event__c ev = new CDO_Audit_Event__c(
            Event_Type__c = eventType,
            Summary__c = summary,
            Details__c = details
        );
        applyRefs(ev, refs);
        return ev;
    }

    /**
     * Files each Id on the lookup that matches its object, whatever key it came under, so a wrong
     * key can never make the insert fail.
     */
    public static void applyRefs(CDO_Audit_Event__c ev, Map<String, Id> refs) {
        if (ev == null || refs == null) {
            return;
        }
        for (String key : refs.keySet()) {
            Id value = refs.get(key);
            if (value == null) {
                continue;
            }
            Schema.SObjectType t = value.getSObjectType();
            if (t == CDO_Work_Item__c.SObjectType) {
                ev.Work_Item__c = value;
            } else if (t == CDO_Promotion__c.SObjectType) {
                ev.Promotion__c = value;
            } else if (t == CDO_Deployment__c.SObjectType) {
                ev.Deployment__c = value;
            } else if (t == CDO_Release__c.SObjectType) {
                ev.Release__c = value;
            }
        }
    }

    private static void stamp(CDO_Audit_Event__c ev) {
        ev.Event_Type__c = String.isBlank(ev.Event_Type__c) ? 'Event' : fit(ev.Event_Type__c, EVENT_TYPE_MAX);
        ev.Summary__c = fit(ev.Summary__c, SUMMARY_MAX);
        ev.Details__c = fit(ev.Details__c, DETAILS_MAX);
        ev.Actor__c = String.isBlank(ev.Actor__c) ? fit(UserInfo.getName(), ACTOR_MAX) : fit(ev.Actor__c, ACTOR_MAX);
        if (String.isBlank(ev.Source__c)) {
            ev.Source__c = source == null ? SOURCE_HUB : source;
        }
        if (ev.Occurred_On__c == null) {
            ev.Occurred_On__c = System.now();
        }
        // A truncated URL is a broken link, so an over-long one is dropped instead.
        if (ev.Run_URL__c != null && ev.Run_URL__c.length() > URL_MAX) {
            ev.Run_URL__c = null;
        }
    }

    private static String fit(String value, Integer maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }
        return value.abbreviate(maxLength);
    }

    /**
     * An audit write never rolls back the change it describes: a row the database refuses is
     * reported in the debug log instead of failing the transaction.
     */
    private static void write(List<CDO_Audit_Event__c> events) {
        List<Database.SaveResult> results = Database.insert(events, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(
                    LoggingLevel.ERROR,
                    'CDO_Audit could not write ' + events[i].Event_Type__c + ': ' + results[i].getErrors()
                );
            }
        }
    }
}
