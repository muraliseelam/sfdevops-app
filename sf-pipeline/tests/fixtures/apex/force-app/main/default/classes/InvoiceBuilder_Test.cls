@IsTest(SeeAllData=false)
private class InvoiceBuilder_Test {
    @IsTest
    static void builds() { System.assertEquals('INV', new InvoiceBuilder().build()); }
}
