@isTest
private class BillingScenarioTests {
    @isTest
    static void outstandingIgnoresPaidAndVoid() {
        System.runAs(InvoiceTestData.invoiceUser()) {
            Account a = new Account(Name = 'Acme');
            Account b = new Account(Name = 'Empty');
            insert new List<Account>{ a, b };
            insert new List<Invoice__c>{
                new Invoice__c(Account__c = a.Id, Amount__c = 100, Status__c = 'Sent'),
                new Invoice__c(Account__c = a.Id, Amount__c = 50, Status__c = 'Draft'),
                new Invoice__c(Account__c = a.Id, Amount__c = 999, Status__c = 'Paid')
            };
            Map<Id, Decimal> totals = InvoiceTotals.outstandingByAccount(new Set<Id>{ a.Id, b.Id });
            Assert.areEqual(150, totals.get(a.Id), 'sent + draft');
            Assert.areEqual(0, totals.get(b.Id), 'no invoices');
        }
    }
}
