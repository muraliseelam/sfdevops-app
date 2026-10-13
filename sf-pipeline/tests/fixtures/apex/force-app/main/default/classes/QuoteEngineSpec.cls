@isTest
private class QuoteEngineSpec {
    @isTest
    static void discounts() { System.assertEquals(90, new QuoteEngine().price(100)); }
}
