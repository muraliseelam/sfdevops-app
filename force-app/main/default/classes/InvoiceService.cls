/**
 * Invoice business rules. Sample code that exercises the pipeline: its test is found by
 * naming convention (InvoiceServiceTest).
 */
public with sharing class InvoiceService {
    public static final Decimal DEFAULT_TAX_RATE = 0.08;

    public static Decimal taxFor(Decimal amount, Decimal rate) {
        if (amount == null || amount <= 0) {
            return 0;
        }
        Decimal r = rate == null ? DEFAULT_TAX_RATE : rate;
        return (amount * r).setScale(2, RoundingMode.HALF_UP);
    }

    public static void markPaid(Set<Id> invoiceIds) {
        if (invoiceIds == null || invoiceIds.isEmpty()) {
            return;
        }
        List<Invoice__c> invoices = [SELECT Id, Status__c FROM Invoice__c WHERE Id IN :invoiceIds WITH USER_MODE];
        for (Invoice__c inv : invoices) {
            if (inv.Status__c == 'Void') {
                throw new InvoiceException('A void invoice cannot be paid: ' + inv.Id);
            }
            inv.Status__c = 'Paid';
        }
        update as user invoices;
    }

    public class InvoiceException extends Exception {}
}
