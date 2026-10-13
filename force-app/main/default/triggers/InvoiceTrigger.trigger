trigger InvoiceTrigger on Invoice__c(before insert, before update) {
    InvoiceTriggerHandler.beforeSave(Trigger.new);
}
