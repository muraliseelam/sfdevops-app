public with sharing class InvoiceController {
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getSummary(Id accountId) {
        Map<Id, Decimal> totals = InvoiceTotals.outstandingByAccount(new Set<Id>{ accountId });
        Integer count = [SELECT COUNT() FROM Invoice__c WHERE Account__c = :accountId WITH USER_MODE];
        return new Map<String, Object>{ 'outstanding' => totals.get(accountId), 'count' => count };
    }
}
