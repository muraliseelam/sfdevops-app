/**
 * DORA metrics for cdoDora, computed from production deployments (Deploy / QuickDeploy rows,
 * not check-only, against a production stage or environment):
 *
 * - Deployment frequency: successful production deploys per week.
 * - Lead time for changes: a work item's first commit → its first successful production deploy
 *   (median, hours). Work items are found directly, through the promotion's junction rows, or
 *   through the release.
 * - Change failure rate: failed / (successful + failed) production deploys, as a percent.
 * - Time to restore (MTTR): first failure of a streak → the next successful deploy (mean, hours).
 *
 * Bands follow the published DORA thresholds (elite / high / medium / low).
 */
public with sharing class DoraController {

    private static final Integer DEFAULT_DAYS = 30;
    private static final Integer MAX_DAYS = 365;

    @AuraEnabled(cacheable=true)
    public static Metrics getMetrics(Id projectId, Integer days) {
        Integer window = (days == null || days <= 0) ? DEFAULT_DAYS : Math.min(days, MAX_DAYS);
        Datetime untilTime = System.now();
        Datetime sinceTime = untilTime.addDays(-window);

        Metrics m = new Metrics();
        m.days = window;
        m.since = sinceTime;
        m.untilTime = untilTime;

        List<CDO_Deployment__c> deploys = productionDeploys(projectId, sinceTime);
        List<CDO_Deployment__c> successes = new List<CDO_Deployment__c>();
        for (CDO_Deployment__c d : deploys) {
            if (d.Status__c == 'Success') {
                successes.add(d);
                m.successfulDeployments++;
            } else {
                m.failedDeployments++;
            }
        }
        m.totalDeployments = deploys.size();

        // Deployment frequency
        Decimal weeks = Decimal.valueOf(window) / 7;
        m.deploymentFrequencyPerWeek = (Decimal.valueOf(m.successfulDeployments) / weeks).setScale(2);
        m.deploymentFrequencyLevel = m.successfulDeployments == 0 ? null : frequencyLevel(m.deploymentFrequencyPerWeek);

        // Change failure rate
        if (m.totalDeployments > 0) {
            m.changeFailureRate = (Decimal.valueOf(m.failedDeployments) * 100 / m.totalDeployments).setScale(1);
            m.changeFailureLevel = failureLevel(m.changeFailureRate);
        }

        // Time to restore: per environment, first failure of a streak → next success.
        Map<String, Datetime> openFailure = new Map<String, Datetime>();
        List<Decimal> restoreHours = new List<Decimal>();
        for (CDO_Deployment__c d : deploys) {
            String envKey = d.Environment__c != null ? String.valueOf(d.Environment__c) : String.valueOf(d.Stage__c);
            Datetime at = eventTime(d);
            if (d.Status__c == 'Failed') {
                if (!openFailure.containsKey(envKey)) {
                    openFailure.put(envKey, at);
                }
            } else if (openFailure.containsKey(envKey)) {
                restoreHours.add(hoursBetween(openFailure.remove(envKey), at));
            }
        }
        m.mttrSampleSize = restoreHours.size();
        if (!restoreHours.isEmpty()) {
            m.mttrHours = mean(restoreHours);
            m.mttrLevel = restoreLevel(m.mttrHours);
        }

        // Lead time for changes
        Map<Id, Datetime> firstProduction = firstProductionByWorkItem(successes);
        Map<Id, Datetime> firstCommit = firstCommitByWorkItem(firstProduction.keySet());
        List<Decimal> leadHours = new List<Decimal>();
        Map<Integer, List<Decimal>> leadByWeek = new Map<Integer, List<Decimal>>();
        for (Id wiId : firstProduction.keySet()) {
            Datetime commitAt = firstCommit.get(wiId);
            Datetime prodAt = firstProduction.get(wiId);
            if (commitAt == null || prodAt < commitAt) {
                continue;
            }
            Decimal h = hoursBetween(commitAt, prodAt);
            leadHours.add(h);
            Integer bucket = weekIndex(sinceTime, prodAt);
            if (!leadByWeek.containsKey(bucket)) {
                leadByWeek.put(bucket, new List<Decimal>());
            }
            leadByWeek.get(bucket).add(h);
        }
        m.leadTimeSampleSize = leadHours.size();
        if (!leadHours.isEmpty()) {
            m.leadTimeHours = median(leadHours);
            m.leadTimeLevel = leadTimeLevel(m.leadTimeHours);
        }

        // Weekly series
        Integer weekCount = Math.ceil(window / 7.0).intValue();
        for (Integer i = 0; i < weekCount; i++) {
            WeekPoint w = new WeekPoint();
            w.weekStart = sinceTime.addDays(i * 7).date();
            w.label = sinceTime.addDays(i * 7).format('MMM d');
            m.weeks.add(w);
        }
        for (CDO_Deployment__c d : deploys) {
            Integer bucket = weekIndex(sinceTime, eventTime(d));
            if (bucket < 0 || bucket >= weekCount) {
                continue;
            }
            if (d.Status__c == 'Success') {
                m.weeks[bucket].deployments++;
            } else {
                m.weeks[bucket].failures++;
            }
        }
        for (Integer bucket : leadByWeek.keySet()) {
            if (bucket >= 0 && bucket < weekCount) {
                m.weeks[bucket].leadTimeHours = median(leadByWeek.get(bucket));
            }
        }
        return m;
    }

    // ----------------------------------------------------------------------------------------

    private static List<CDO_Deployment__c> productionDeploys(Id projectId, Datetime sinceTime) {
        String soql =
            'SELECT Id, Status__c, Event_Type__c, Work_Item__c, Promotion__c, Release__c, Stage__c, Environment__c, ' +
            'Started_On__c, Completed_On__c, CreatedDate FROM CDO_Deployment__c ' +
            'WHERE Event_Type__c IN (\'Deploy\', \'QuickDeploy\') AND Check_Only__c = false ' +
            'AND Status__c IN (\'Success\', \'Failed\') AND CreatedDate >= :sinceTime ' +
            'AND (Stage__r.Is_Production__c = true OR Environment__r.Type__c = \'Production\')' +
            (projectId == null ? '' : ' AND (Stage__r.Project__c = :projectId OR Environment__r.Project__c = :projectId)') +
            ' ORDER BY CreatedDate ASC, Id ASC LIMIT 10000';
        List<CDO_Deployment__c> rows = (List<CDO_Deployment__c>) Database.queryWithBinds(
            soql, new Map<String, Object>{ 'sinceTime' => sinceTime, 'projectId' => projectId }, AccessLevel.SYSTEM_MODE);
        // Re-sort on the event time the metrics use (completion first), keeping the Id tie-break.
        List<DeployOrder> ordered = new List<DeployOrder>();
        for (CDO_Deployment__c d : rows) {
            ordered.add(new DeployOrder(d));
        }
        ordered.sort();
        List<CDO_Deployment__c> out = new List<CDO_Deployment__c>();
        for (DeployOrder o : ordered) {
            out.add(o.d);
        }
        return out;
    }

    /** Work item → time of its first successful production deploy in the window. */
    private static Map<Id, Datetime> firstProductionByWorkItem(List<CDO_Deployment__c> successes) {
        Set<Id> promotionIds = new Set<Id>();
        Set<Id> releaseIds = new Set<Id>();
        for (CDO_Deployment__c d : successes) {
            if (d.Promotion__c != null) {
                promotionIds.add(d.Promotion__c);
            }
            if (d.Release__c != null) {
                releaseIds.add(d.Release__c);
            }
        }
        Map<Id, Set<Id>> byPromotion = new Map<Id, Set<Id>>();
        if (!promotionIds.isEmpty()) {
            for (CDO_Promoted_Work_Item__c j : [
                SELECT Promotion__c, Work_Item__c FROM CDO_Promoted_Work_Item__c
                WHERE Promotion__c IN :promotionIds AND Work_Item__c != null
            ]) {
                if (!byPromotion.containsKey(j.Promotion__c)) {
                    byPromotion.put(j.Promotion__c, new Set<Id>());
                }
                byPromotion.get(j.Promotion__c).add(j.Work_Item__c);
            }
        }
        Map<Id, Set<Id>> byRelease = new Map<Id, Set<Id>>();
        if (!releaseIds.isEmpty()) {
            for (CDO_Work_Item__c wi : [SELECT Id, Release__c FROM CDO_Work_Item__c WHERE Release__c IN :releaseIds]) {
                if (!byRelease.containsKey(wi.Release__c)) {
                    byRelease.put(wi.Release__c, new Set<Id>());
                }
                byRelease.get(wi.Release__c).add(wi.Id);
            }
        }
        Map<Id, Datetime> first = new Map<Id, Datetime>();
        for (CDO_Deployment__c d : successes) {
            Set<Id> items = new Set<Id>();
            if (d.Work_Item__c != null) {
                items.add(d.Work_Item__c);
            }
            if (d.Promotion__c != null && byPromotion.containsKey(d.Promotion__c)) {
                items.addAll(byPromotion.get(d.Promotion__c));
            }
            if (d.Release__c != null && byRelease.containsKey(d.Release__c)) {
                items.addAll(byRelease.get(d.Release__c));
            }
            Datetime at = eventTime(d);
            for (Id wiId : items) {
                if (!first.containsKey(wiId) || at < first.get(wiId)) {
                    first.put(wiId, at);
                }
            }
        }
        return first;
    }

    private static Map<Id, Datetime> firstCommitByWorkItem(Set<Id> workItemIds) {
        Map<Id, Datetime> first = new Map<Id, Datetime>();
        if (workItemIds.isEmpty()) {
            return first;
        }
        for (AggregateResult ar : [
            SELECT Work_Item__c wi, MIN(Committed_On__c) firstCommitted, MIN(CreatedDate) firstCreated
            FROM CDO_Commit__c
            WHERE Work_Item__c IN :workItemIds
            GROUP BY Work_Item__c
        ]) {
            Datetime committed = (Datetime) ar.get('firstCommitted');
            Datetime created = (Datetime) ar.get('firstCreated');
            first.put((Id) ar.get('wi'), committed != null ? committed : created);
        }
        return first;
    }

    private static Datetime eventTime(CDO_Deployment__c d) {
        if (d.Completed_On__c != null) {
            return d.Completed_On__c;
        }
        return d.Started_On__c != null ? d.Started_On__c : d.CreatedDate;
    }

    private static Integer weekIndex(Datetime sinceTime, Datetime at) {
        Long ms = at.getTime() - sinceTime.getTime();
        return Math.floor(ms / (7 * 24 * 3600 * 1000.0)).intValue();
    }

    private static Decimal hoursBetween(Datetime a, Datetime b) {
        return Decimal.valueOf(b.getTime() - a.getTime()) / 3600000;
    }

    @TestVisible
    private static Decimal median(List<Decimal> values) {
        List<Decimal> sorted = new List<Decimal>(values);
        sorted.sort();
        Integer n = sorted.size();
        Decimal mid = Math.mod(n, 2) == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
        return mid.setScale(1);
    }

    private static Decimal mean(List<Decimal> values) {
        Decimal total = 0;
        for (Decimal v : values) {
            total += v;
        }
        return (total / values.size()).setScale(1);
    }

    @TestVisible
    private static String frequencyLevel(Decimal perWeek) {
        if (perWeek >= 7) {
            return 'Elite';
        }
        if (perWeek >= 1) {
            return 'High';
        }
        return perWeek >= 0.25 ? 'Medium' : 'Low';
    }

    @TestVisible
    private static String leadTimeLevel(Decimal hours) {
        if (hours < 24) {
            return 'Elite';
        }
        if (hours < 168) {
            return 'High';
        }
        return hours < 720 ? 'Medium' : 'Low';
    }

    @TestVisible
    private static String failureLevel(Decimal percent) {
        if (percent <= 5) {
            return 'Elite';
        }
        if (percent <= 10) {
            return 'High';
        }
        return percent <= 15 ? 'Medium' : 'Low';
    }

    @TestVisible
    private static String restoreLevel(Decimal hours) {
        if (hours < 1) {
            return 'Elite';
        }
        if (hours < 24) {
            return 'High';
        }
        return hours < 168 ? 'Medium' : 'Low';
    }

    // ----------------------------------------------------------------------------------------

    private class DeployOrder implements Comparable {
        CDO_Deployment__c d;
        Long at;
        DeployOrder(CDO_Deployment__c d) {
            this.d = d;
            this.at = eventTime(d).getTime();
        }
        public Integer compareTo(Object other) {
            DeployOrder o = (DeployOrder) other;
            if (at != o.at) {
                return at < o.at ? -1 : 1;
            }
            String a = String.valueOf(d.Id);
            String b = String.valueOf(o.d.Id);
            return a == b ? 0 : (a < b ? -1 : 1);
        }
    }

    public class Metrics {
        @AuraEnabled public Integer days;
        @AuraEnabled public Datetime since;
        @AuraEnabled public Datetime untilTime;
        @AuraEnabled public Integer totalDeployments = 0;
        @AuraEnabled public Integer successfulDeployments = 0;
        @AuraEnabled public Integer failedDeployments = 0;
        @AuraEnabled public Decimal deploymentFrequencyPerWeek = 0;
        @AuraEnabled public String deploymentFrequencyLevel;
        @AuraEnabled public Decimal leadTimeHours;
        @AuraEnabled public Integer leadTimeSampleSize = 0;
        @AuraEnabled public String leadTimeLevel;
        @AuraEnabled public Decimal changeFailureRate;
        @AuraEnabled public String changeFailureLevel;
        @AuraEnabled public Decimal mttrHours;
        @AuraEnabled public Integer mttrSampleSize = 0;
        @AuraEnabled public String mttrLevel;
        @AuraEnabled public List<WeekPoint> weeks = new List<WeekPoint>();
    }

    public class WeekPoint {
        @AuraEnabled public Date weekStart;
        @AuraEnabled public String label;
        @AuraEnabled public Integer deployments = 0;
        @AuraEnabled public Integer failures = 0;
        @AuraEnabled public Decimal leadTimeHours;
    }
}
