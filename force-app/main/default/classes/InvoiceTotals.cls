/**
 * Aggregates invoice amounts per account. Its only test is BillingScenarioTests, whose name
 * looks nothing like this class: only the org's coverage map (pass 1 of the test resolver)
 * can find it.
 */
public with sharing class InvoiceTotals {
    private static final Set<String> OPEN_STATUSES = new Set<String>{ 'Draft', 'Sent' };

    public static Map<Id, Decimal> outstandingByAccount(Set<Id> accountIds) {
        Map<Id, Decimal> totals = new Map<Id, Decimal>();
        Set<String> openStatuses = OPEN_STATUSES;
        for (AggregateResult ar : [
            SELECT Account__c acc, SUM(Amount__c) total
            FROM Invoice__c
            WHERE Account__c IN :accountIds AND Status__c IN :openStatuses
            WITH USER_MODE
            GROUP BY Account__c
        ]) {
            totals.put((Id) ar.get('acc'), (Decimal) ar.get('total'));
        }
        for (Id accountId : accountIds) {
            if (!totals.containsKey(accountId)) {
                totals.put(accountId, 0);
            }
        }
        return totals;
    }
}
