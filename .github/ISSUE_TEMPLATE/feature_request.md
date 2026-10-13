---
name: Feature request
about: Propose a change to the pipeline, the hub app or the setup
title: "Feature: "
labels: enhancement
---

## The problem

<!-- What can you not do today, or what costs you time? Describe the situation, not the solution. -->

## The proposal

<!-- What should happen instead? Which part changes: a workflow, a script, the config, the hub app? -->

## Fit with the product rules

<!-- The rules in docs/PRODUCT-DESIGN.md §1 are non-negotiable. Tick what your proposal keeps. -->

- [ ] Deploy, then merge (no branch is merged before its org is deployed)
- [ ] The pull request stays a review gate, never a merge path
- [ ] The delta stays computed against the target environment
- [ ] Everything of consequence still writes a hub audit record
- [ ] No environment name, branch name or org count is hardcoded (new knobs go in `pipeline.config.yml`)

## Contract impact

- [ ] None
- [ ] Changes a workflow dispatch input or a callback payload (both sides + `docs/CONTRACTS.md` must change)

## Cost

<!-- Every decision here has a cost (see "Decisions and their costs"). What does this one cost:
     time, complexity, a second system to keep in step, weaker guarantees? -->

## Alternatives considered
