# Contributing to SF DevOps

Thank you for helping. This project has two halves on two branches:

| Branch | What | Open your PR against |
| --- | --- | --- |
| `main` | The pipeline (`.github/workflows/`, `sf-pipeline/`), the sample metadata (`force-app/`), the docs | `main` |
| `platform/sfdevops-app` | The Salesforce hub app (sfdx project, package directory `sfdevops-app/`) | `platform/sfdevops-app` |

Read [docs/PRODUCT-DESIGN.md](docs/PRODUCT-DESIGN.md) first: the product rules and the decisions
(and their costs) explain most review comments before they are made.

## Development setup

```bash
git clone https://github.com/muraliseelam/sfdevops-app.git
cd sfdevops-app
# the hub app next to it, as a worktree (.platform/ is git-ignored on main)
git fetch origin 'refs/heads/platform/*:refs/remotes/origin/platform/*'
git worktree add .platform/hub platform/sfdevops-app
```

You need:

- git, bash (Git Bash on Windows), Python 3.10+ with PyYAML (`python3 -m pip install pyyaml`; on
  Windows `py -m pip install pyyaml`);
- for the delta test: the Salesforce CLI and the sfdx-git-delta plugin
  (`bash sf-pipeline/scripts/install-sf.sh` installs the pinned versions; the test skips cleanly
  without them);
- for LWC Jest: Node 22 (`npm ci`);
- for hub work: the Salesforce CLI and an org you can deploy to (a scratch org works).

## Running the tests

Everything that runs in `ci-selftest` runs locally, without an org or secrets.

```bash
# Python unit tests (Windows: py -m unittest ...)
python3 -m unittest discover -s sf-pipeline/tests

# bash tests, including the pure-git promotion simulation
for t in sf-pipeline/tests/test_*.sh; do bash "$t" || echo "FAILED: $t"; done

# or both at once
bash sf-pipeline/tests/run_tests.sh

# the promotion simulation alone (27 assertions: no clobber, conflict abort, target moved,
# protected push, deterministic rebuild)
bash sf-pipeline/tests/test_promotion_sim.sh

# workflow lint, as CI runs it (https://github.com/rhysd/actionlint, version 1.7.12)
actionlint -shellcheck= -pyflakes=

# LWC Jest for the sample app
npm ci && npm run test:unit
```

Hub app (from `.platform/hub`):

```bash
py tools/gen_metadata.py --check && py tools/gen_permissions.py --check   # generated metadata is current
sf apex run test -o <hub-org> --code-coverage --result-format human --wait 30 \
  --class-names CDO_Tests,CDO_ControllerTests,CDO_PromotionReconcilerTest,CDOWorkItemCommandCenterTest,StoryBoardControllerTest
```

The hub's objects, fields, layouts, object tabs and permission sets are **generated** from
`tools/objects.yml` by `tools/gen_metadata.py` and `tools/gen_permissions.py`. Edit the YAML or the
generators and regenerate; never hand-edit a generated file (see `tools/README.md` on that branch).

## Rules for changes

- **Nothing hardcodes an environment name, a branch name or an org count** in `.github/workflows/`
  or `sf-pipeline/`. Resolve them through `plan.py`. Add a config key (with a default in `plan.py`,
  a comment in `pipeline.config.yml`, a test, and a row in
  [DEVOPS.md → Config reference](docs/DEVOPS.md#config-reference)) when you need a new knob. The
  fixtures `config-3env.yml` and `config-5env.yml` must keep working without file changes.
- **Deploy, then merge.** Never merge an environment branch before its deploy succeeded, never
  force-push or reset an environment branch, never report success through a rejected push.
- **Never print, log or commit a secret.** Secrets travel through stdin, private temp files
  (`umask 077`, removed by a trap) and `::add-mask::`. Never put a secret on a command line.
- **Least privilege.** Every workflow declares explicit `permissions:`; ask for no more than it uses.
- **Believe the deploy id, not the exit code**, and never pipe a deploy through `tail`.
- **Bash:** `set -euo pipefail`, explicit refspecs when fetching, LF line endings (`.gitattributes`
  enforces them).
- **Tests:** every script change comes with a test under `sf-pipeline/tests/`. Algorithms that touch
  git (promotion, delta) need a simulation, not only a mock.
- **Docs:** update the doc that describes the behaviour you changed, in the same PR. Docs describe
  what the code does; mark anything unproven against live orgs as "Evidence: pending live run".

## Contract changes

The hub and the pipeline meet only at the contracts in [docs/CONTRACTS.md](docs/CONTRACTS.md)
(workflow dispatch inputs, the callback payloads, the REST endpoints). A contract change must:

1. change **both sides**: a PR to `main` (workflows, `hub_payload.py`, scripts) and a PR to
   `platform/sfdevops-app` (Apex), cross-linked and merged together;
2. update **CONTRACTS.md** in the `main` PR;
3. stay tolerant: the hub ignores unknown callback attributes, so an additive field can ship on the
   pipeline side first; removing or renaming a field or a dispatch input needs both sides at once.
   Dispatch inputs are strings, always.

## Commit conventions

- One logical change per commit.
- Subject: an imperative sentence, at most 72 characters, no prefix and no trailing period, for
  example `Add the promotion-branch algorithm, deploy action and contracts`.
- Body (when needed): why the change is made and what it costs, wrapped at 72 characters.
- No generated-by or co-author trailers for tools; commits are authored by the person responsible.

## Pull requests

Fill in the [pull request template](.github/pull_request_template.md). CI (`ci-selftest`) must be
green. For changes to business metadata in your own adoption of the pipeline, remember the
`Specified-Tests: A, B` line in the PR description to name Apex tests explicitly.

## Reporting bugs and proposing features

Use the issue templates. Report security problems privately, as described in
[SECURITY.md](SECURITY.md), not in a public issue.

By contributing you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE), and you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
