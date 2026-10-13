/**
 * Test helper: a user who holds the Invoice_User permission set. The invoice code queries
 * WITH USER_MODE, so tests run as someone who has exactly the access a real invoice user has;
 * deploying a field grants nobody access to it, not even the admin running the tests.
 */
@isTest
public class InvoiceTestData {
    public static User invoiceUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '') + DateTime.now().getTime();
        User u = new User(
            Alias = 'invusr',
            Email = 'invoice.user@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Invoice User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'invoice.user.' + unique + '@example.com.test'
        );
        insert u;
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Invoice_User' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        return u;
    }
}
