# Signing the pipeline in to Salesforce

Every workflow job signs in to one org with the secrets of the GitHub Environment it runs in
(`sf-pipeline/scripts/auth-jwt.sh`; the hub uses `auth-hub.sh` and repository secrets). Two modes
are supported. `bootstrap_secrets.py` sets up either one (see [docs/SETUP.md](../../docs/SETUP.md),
step 10).

| | SFDX auth URL (default) | JWT bearer |
| --- | --- | --- |
| Secrets | `SF_AUTH_URL` (+ `SF_USERNAME`, `SF_INSTANCE_URL`) | `SF_CONSUMER_KEY`, `SF_JWT_KEY` (+ `SF_USERNAME`, `SF_INSTANCE_URL`) |
| Needs in each org | Nothing beyond a CLI login (`sf org login web`) | A Connected App **or** an External Client App holding your certificate |
| What is stored | A refresh token from a CLI login | A private key; no refresh token |
| Acts as | The user who logged in | The username in `SF_USERNAME` (must be pre-authorized on the app) |
| Revocation | Revoke the CLI's OAuth token for that user (Setup → Connected Apps OAuth Usage) | Remove the user's pre-authorization or the certificate |
| Trade-off | Simplest; works where Connected Apps are blocked. Anyone holding the secret can use the org as that user until it is revoked | No stored refresh token; one app per org to create and keep |

The sign-in scripts use JWT whenever `SF_CONSUMER_KEY`, `SF_USERNAME` and `SF_JWT_KEY` are all set,
and the auth URL otherwise.

## Salesforce now refuses many new Connected Apps

Creating a new Connected App fails in many orgs with:

> You can't create a connected app. To enable connected app creation, contact Salesforce Customer
> Support.

The reference orgs for this project returned exactly that (a check-only deploy of a probe app, with a
throwaway certificate). So the pipeline defaults to the SFDX auth URL, and for JWT you have two
choices: an **External Client App** (works where Connected Apps are blocked), or the reference
**Connected App** in this folder (for orgs that still allow them). Deploying
`SFDevOps_CI.connectedApp-meta.xml` has not been possible in the reference orgs:
**Evidence: pending live run** in an org that allows Connected Apps.

## 1. The certificate (both JWT options)

One key pair can serve every org. Generate it outside the repository, in `~/.sfdevops/`, where
`bootstrap_secrets.py --jwt` looks for it:

```bash
mkdir -p ~/.sfdevops
MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout ~/.sfdevops/server.key -out ~/.sfdevops/server.crt -subj "/CN=sfdevops-ci"
```

`MSYS_NO_PATHCONV=1` stops Git Bash on Windows from rewriting `/CN=...` into a path. Upload
**`server.crt`** (the public certificate) to the app. **`server.key` never leaves your machine** except
as the `SF_JWT_KEY` secret, which `bootstrap_secrets.py` stores (base64, one line) without printing it.

## 2a. External Client App (works where Connected Apps are blocked)

In each org (and the hub, if it uses JWT), in Setup:

1. **App Manager → New External Client App.** Give it a name (for example `SF DevOps CI`), a contact
   email, and distribution state **Local**.
2. **Enable OAuth.** Callback URL `http://localhost:1717/OauthRedirect`.
3. **OAuth scopes:** *Manage user data via APIs (api)*, *Perform requests at any time
   (refresh_token, offline_access)*, *Manage user data via Web browsers (web)*.
4. **Use digital signatures / enable the JWT bearer flow** and upload `server.crt`.
5. Save. In the app's **Policies**, set **Permitted users: Admin approved users are
   pre-authorized**, and add the integration user's **profile or permission set** to the app.
   Relax IP restrictions if your runners' IPs are not trusted (GitHub-hosted runners have changing
   addresses).
6. In the app's OAuth settings, copy the **Consumer Key**.

Setup labels move between Salesforce releases; the essentials are: OAuth on, the three scopes, the
certificate for JWT, admin-approved users pre-authorized, the integration user's profile or
permission set assigned, and the consumer key.

## 2b. The reference Connected App (orgs that still allow it)

`connectedApps/SFDevOps_CI.connectedApp-meta.xml` defines **SF DevOps CI**: callback
`http://localhost:1717/OauthRedirect`, scopes `Api`, `RefreshToken`, `Web`, **admin-approved users
only** (`isAdminApproved`), IP relaxation `BYPASS`, and the `System Administrator` profile
pre-authorized. `package.xml` names it for manifest-based tools.

Before deploying:

1. Replace `contactEmail`.
2. Replace the certificate placeholder comment with a `<certificate>` element holding the contents
   of `server.crt` (PEM, including the `BEGIN CERTIFICATE` / `END CERTIFICATE` lines).
3. If your integration user does not use the `System Administrator` profile, change `profileName`
   (or pre-authorize a permission set in Setup after deploying).

The certificate is public by nature and may be committed. The private key must never be in the
repository (`.gitignore` ignores `*.key`, `*.pem` and `.sfdevops/`), and `config/commit-denylist.txt`
keeps `sf-commit` from ever writing a `ConnectedApp` into a feature branch.

Deploy and read the consumer key:

```bash
sf project deploy start --source-dir sf-pipeline/connected-app/connectedApps --target-org acme-int --wait 10
```

Then Setup → App Manager → SF DevOps CI → View → **Consumer Key**. A new Connected App can take a few
minutes before JWT logins succeed.

## 3. Store the secrets

Collect the consumer keys by org alias and run bootstrap in JWT mode:

```json
{ "acme-dev": "3MVG...", "acme-int": "3MVG...", "acme-qa": "3MVG...", "acme-stage": "3MVG...",
  "acme-prod": "3MVG...", "acme-hub": "3MVG..." }
```

```bash
py sf-pipeline/scripts/bootstrap_secrets.py --jwt --consumer-keys keys.json   # macOS/Linux: python3
```

Keep `keys.json` out of the repository. Then run the `sf-auth-check` workflow.

Verify one org by hand before wiring anything up:

```bash
sf org login jwt --client-id <consumer key> --jwt-key-file ~/.sfdevops/server.key \
  --username <integration user> --instance-url https://<my-domain>.my.salesforce.com --alias jwt-check
sf org display --target-org jwt-check
```

## The auth URL mode (default)

Nothing to create in the org: log in with `sf org login web --alias <alias>` as the user the pipeline
should act as, and run `bootstrap_secrets.py` without `--jwt`. To set one secret by hand without
printing it:

```bash
sf org auth show-sfdx-auth-url --target-org acme-int --json \
  | py -c "import json,sys; print(json.load(sys.stdin)['result']['sfdxAuthUrl'])" \
  | gh secret set SF_AUTH_URL --env int
```

A login made with JWT, or a scratch org of a JWT-authorized Dev Hub, has no refresh token and
therefore no auth URL.
