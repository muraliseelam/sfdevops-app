@isTest
private class InvoiceTriggerHandlerTest {
    @isTest
    static void taxAndDefaultStatusAreSet() {
        Invoice__c inv = new Invoice__c(Amount__c = 200);
        insert inv;
        Invoice__c saved = [SELECT Status__c, Tax__c FROM Invoice__c WHERE Id = :inv.Id];
        Assert.areEqual('Draft', saved.Status__c, 'default status');
        Assert.areEqual(16.00, saved.Tax__c, 'tax at the default rate');
    }
}
