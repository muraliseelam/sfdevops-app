public with sharing class InvoiceTriggerHandler {
    public static void beforeSave(List<Invoice__c> invoices) {
        for (Invoice__c inv : invoices) {
            if (String.isBlank(inv.Status__c)) {
                inv.Status__c = 'Draft';
            }
            inv.Tax__c = InvoiceService.taxFor(inv.Amount__c, null);
        }
    }
}
