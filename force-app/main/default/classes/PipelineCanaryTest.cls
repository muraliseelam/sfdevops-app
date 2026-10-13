/**
 * The production canary (pipeline.config.yml → production.destructive_tests). Production
 * forbids NoTestRun whenever Apex is involved, deletions included; a deletion has no coverage
 * requirement, so one stable passing test satisfies the platform without running the whole
 * org suite. Keep it trivial and always green.
 */
@isTest
private class PipelineCanaryTest {
    @isTest
    static void canary() {
        Assert.isTrue(true, 'The canary always passes.');
    }
}
