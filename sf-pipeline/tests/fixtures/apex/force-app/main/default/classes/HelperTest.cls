// Not a test despite its name: a utility that happens to end in Test.
// Mentioning @isTest in a comment must not make it one.
public with sharing class HelperTest {
    public static String describe() { return Helper.name(); }
}
