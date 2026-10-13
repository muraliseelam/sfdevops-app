@isTest
private class InvoiceServiceTest {
    @isTest
    static void taxUsesTheGivenRateOrTheDefault() {
        Assert.areEqual(10.00, InvoiceService.taxFor(100, 0.10), 'explicit rate');
        Assert.areEqual(8.00, InvoiceService.taxFor(100, null), 'default rate');
        Assert.areEqual(0, InvoiceService.taxFor(0, 0.10), 'no tax on zero');
        Assert.areEqual(0, InvoiceService.taxFor(null, 0.10), 'no tax on null');
    }

    @isTest
    static void markPaidUpdatesStatus() {
        System.runAs(InvoiceTestData.invoiceUser()) {
            Invoice__c inv = new Invoice__c(Amount__c = 50, Status__c = 'Sent');
            insert inv;
            Test.startTest();
            InvoiceService.markPaid(new Set<Id>{ inv.Id });
            InvoiceService.markPaid(new Set<Id>());
            Test.stopTest();
            Assert.areEqual('Paid', [SELECT Status__c FROM Invoice__c WHERE Id = :inv.Id].Status__c, 'paid');
        }
    }

    @isTest
    static void voidInvoiceCannotBePaid() {
        System.runAs(InvoiceTestData.invoiceUser()) {
            Invoice__c inv = new Invoice__c(Amount__c = 50, Status__c = 'Void');
            insert inv;
            try {
                InvoiceService.markPaid(new Set<Id>{ inv.Id });
                Assert.fail('expected an exception');
            } catch (InvoiceService.InvoiceException e) {
                Assert.isTrue(e.getMessage().contains('void'), e.getMessage());
            }
        }
    }
}
