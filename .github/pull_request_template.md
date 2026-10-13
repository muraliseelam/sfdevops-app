## What and why

<!-- What this PR changes and why. Link the issue or work item (e.g. WI-0032). -->

## Specified tests (business metadata PRs)

<!-- The pipeline finds Apex tests for changed classes automatically (coverage map, naming
     convention, changed test classes). To name them explicitly for this PR's validation and its
     entry deploy, add your own line to this description that starts with the words
     "Specified-Tests:" followed by comma-separated class names, for example
     -> Specified-Tests: InvoiceServiceTest, InvoiceTriggerHandlerTest
     Only add that line when you have names to put on it: the pipeline reads any line that starts
     with "Specified-Tests:", even inside this comment, so this template never starts a line with
     it. RunSpecifiedTests counts coverage only from the tests that run, so name every relevant
     class. -->

## Checklist

For pipeline or platform changes:

- [ ] Tests added or updated under `sf-pipeline/tests/` (or hub Apex tests); `bash sf-pipeline/tests/run_tests.sh` passes
- [ ] `actionlint` is clean (workflow changes)
- [ ] No environment name, branch name or org count is hardcoded outside `pipeline.config.yml`
- [ ] No secret is printed, logged, passed on a command line or committed
- [ ] Workflow `permissions:` stay least-privilege
- [ ] Contract change? Both sides changed and `docs/CONTRACTS.md` updated (link the paired PR)
- [ ] Docs updated for any behaviour change; unproven behaviour marked "Evidence: pending live run"

For business metadata (your adoption of the pipeline):

- [ ] The validation comment on this PR is green before you ask for approval
- [ ] Merge conflicts reported by the pipeline are resolved on the feature branch

<!-- Reminder: this PR is a review gate. Do not use the merge button: approval starts the deploy,
     and the pipeline merges after it succeeds. -->
