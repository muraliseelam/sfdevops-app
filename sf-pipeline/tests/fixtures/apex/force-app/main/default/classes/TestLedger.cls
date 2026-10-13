public class TestLedger {
    static testMethod void startsAtZero() { System.assertEquals(0, new Ledger().total); }
}
