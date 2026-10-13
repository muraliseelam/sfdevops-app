@isTest
private class InvoiceControllerTest {
    @isTest
    static void summaryCountsAndTotals() {
        System.runAs(InvoiceTestData.invoiceUser()) {
            Account a = new Account(Name = 'Acme');
            insert a;
            insert new Invoice__c(Account__c = a.Id, Amount__c = 40, Status__c = 'Sent');
            Map<String, Object> s = InvoiceController.getSummary(a.Id);
            Assert.areEqual(1, (Integer) s.get('count'), 'count');
            Assert.areEqual(40, (Decimal) s.get('outstanding'), 'outstanding');
        }
    }
}
