---
name: Bug report
about: Something in the pipeline or the hub app does not behave as documented
title: "Bug: "
labels: bug
---

<!-- Security problems: do not file them here. See SECURITY.md. Never paste secrets, auth URLs,
     tokens or private keys; workflow logs never print them, so a log excerpt is safe to share. -->

## What happened

<!-- One or two sentences. -->

## What you expected

<!-- And where it is documented, if it is (link the doc section). -->

## Where

- [ ] Pipeline (workflow / composite action / script on `main`)
- [ ] Hub app (branch `platform/sfdevops-app`)
- [ ] Setup scripts (`bootstrap_secrets.py`, `seed-pipeline.py`, `onboard-org.sh`, `grant-app-access.sh`, `setup-branch-protection.sh`)
- [ ] Documentation

Workflow or component name:

## How to reproduce

1.
2.
3.

## Evidence

- Workflow run URL (if public), or the relevant log lines:
- Deploy id (if a deploy was involved):
- Hub record (work item / promotion / deployment name), if relevant:

```text
paste the relevant log lines here
```

## Environment

- Commit SHA of `sf-pipeline/` you run:
- Number of environments in `pipeline.config.yml`, and `delta_baseline`:
- Sign-in mode: auth URL / JWT (Connected App or External Client App)
- Hub configured: yes / no (GitHub-only mode)
- Salesforce CLI version (`sf --version`), if run locally:
- OS (for setup scripts): Windows (Git Bash / PowerShell) / macOS / Linux
