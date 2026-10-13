# Security

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue or pull request.

1. Use GitHub's private vulnerability reporting: on the repository page, **Security → Report a
   vulnerability**.
2. If that option is not available, open a public issue that says only "security contact
   requested" (no details), and the maintainer will arrange a private channel.

Include what you found, how to reproduce it, and the impact you expect. You will get an
acknowledgement, and a fix or mitigation plan, as soon as the maintainer can investigate. Please
give a reasonable time to fix before any public disclosure.

Supported versions: the latest commit on `main` and on `platform/sfdevops-app`. There are no
long-term support releases yet.

## The secrets model

The platform touches Salesforce orgs and a GitHub repository, so it handles powerful credentials.
This is where each one lives and how it is protected.

### What is stored where

| Credential | Stored in | Set by | Used by |
| --- | --- | --- | --- |
| Org sign-in: `SF_AUTH_URL` (default) or `SF_CONSUMER_KEY` + `SF_JWT_KEY`, plus `SF_USERNAME`, `SF_INSTANCE_URL` | The secrets of **that org's GitHub Environment** (one per org; production's in `prod-validate` and `prod`) | `bootstrap_secrets.py` | Jobs that run in that environment only |
| Hub sign-in: `HUB_AUTH_URL` or `HUB_CONSUMER_KEY` + `HUB_JWT_KEY`, plus `HUB_USERNAME`, `HUB_INSTANCE_URL` | Repository secrets | `bootstrap_secrets.py` | Callback steps |
| GitHub token for the hub | The hub's External Credential `GitHub_API_Credential` (principal `GitHub_PAT`, parameter `Token`), encrypted by Salesforce | `bootstrap_secrets.py` (hidden prompt, sent over HTTPS to the Connect API), or by hand in Setup | `GitHubService` (workflow dispatch), the reconciler |
| `GH_PAT` (optional) | Repository secret | `bootstrap_secrets.py` (unless `--no-gh-pat`) or `gh secret set` | Pushes, PR creation and PR-path merges |
| JWT private key | `~/.sfdevops/server.key` on the maintainer's machine, and base64 in `SF_JWT_KEY` / `HUB_JWT_KEY` | You / `bootstrap_secrets.py` | `auth-jwt.sh`, `auth-hub.sh` |
| `SONAR_TOKEN`, Webex tokens (optional) | Repository secrets | You | The quality and notify steps |

**No secret lives in source or metadata.** The Named Credential and External Credential metadata
carry no token. `.gitignore` excludes `*.key`, `*.pem`, `server.key*` and `.sfdevops/`.

### What never leaves the runner

- Keys and auth URLs are written to private temp files (`mktemp` under `umask 077`) and deleted by a
  trap on exit. They are never echoed and never passed on a command line.
- The hub access token is masked with `::add-mask::` and sent from a private header file, so it
  appears neither in the log nor in a process listing.
- Callback payloads, PR comments and job summaries carry results only (ids, coverage, test names,
  component names), never credentials. On a public repository, workflow logs are public: the scripts
  are written for that.
- `bootstrap_secrets.py` passes every secret to `gh secret set` on stdin and prints only names.

### The commit deny-list

`sf-commit` retrieves only the components a developer selected, and drops anything matching
`sf-pipeline/config/commit-denylist.txt` before it reaches git: `ConnectedApp`, `NamedCredential`,
`ExternalCredential`, `AuthProvider`, `Certificate`, `Settings`, `InstalledPackage`,
`SamlSsoConfig`. Credential metadata and org-wide settings therefore never enter a feature branch.

### Least-privilege workflow permissions

Every workflow declares explicit `permissions:`. Read-only workflows (`sf-conflict-check`,
`sf-list-changes`, `sf-data-deploy`, `sf-auth-check`, `ci-selftest`) get `contents: read`; only the
workflows that push, comment, label or set commit statuses get those write scopes. See
[docs/DEVOPS.md → Workflows](docs/DEVOPS.md#workflows) for each one.

### Gates that cannot be talked around

- **Fork PRs get no secrets.** GitHub does not pass secrets to `pull_request` runs from forks, and
  `sf-pr-validation` skips them with a warning.
- **The `approved` label on the entry stage and the `bypass-quality-gates` label** count only from
  repository admins or maintainers, re-verified at run time through the GitHub collaborators
  permission API; anyone else's label is removed with a comment.
- **Production** deploys only from the `prod` GitHub Environment with a required reviewer, after a
  validation, and only the validated, byte-identical payload is quick-deployed.
- **Branch protection** requires the `sfdevops/deploy` status (set only on deployed promotions),
  blocks force pushes and deletions, and is enforced for admins on every branch except the entry.
- **The hub's audit trail is append-only:** a validation rule blocks edits to `CDO_Audit_Event__c`
  and no permission set grants delete.

### Known trade-offs

- **SFDX auth URL mode stores a refresh token.** It acts as the user who logged in and stays valid
  until revoked. Use a dedicated integration user with only the access the pipeline needs, and
  revoke the token (Setup → Connected Apps OAuth Usage) if a secret may have leaked. JWT mode stores
  no refresh token; see [sf-pipeline/connected-app/README.md](sf-pipeline/connected-app/README.md).
- **The GitHub token** can push and dispatch workflows. Use a fine-grained token limited to this
  repository, set an expiry, and rotate it by re-running `bootstrap_secrets.py`.
- **The entry branch is not admin-enforced** (so the pipeline's admin token can merge into it
  directly). A repository admin could therefore bypass protection there; the audit trail and the
  PR history show it.
- **A callback failure is a warning** so that a hub outage cannot roll back delivery; the hub can
  lag until the reconciler catches up.

If you rotate a credential, re-run `bootstrap_secrets.py` and then the `sf-auth-check` workflow.
