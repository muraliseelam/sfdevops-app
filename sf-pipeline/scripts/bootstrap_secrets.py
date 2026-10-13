#!/usr/bin/env python3
"""bootstrap_secrets.py — wire every org in pipeline.config.yml into GitHub, in one run.

Run it yourself, once, from a checkout of the repository, with every org already logged in to
the Salesforce CLI under the `org_alias` the config names, and the GitHub CLI logged in as a
repository admin. It never prints a secret.

What it does
  1. Creates the GitHub Environments the config needs (each source org, each environment,
     production's validate environment, and production's deploy environment WITH you as the
     required reviewer).
  2. For each org, stores the credentials the workflows sign in with, as secrets of that
     org's GitHub Environment (production's org goes into both production environments):
       - auth-url mode (default): SF_AUTH_URL, read from your local CLI login. Works on every
         org, including orgs where Salesforce no longer allows creating Connected Apps.
       - jwt mode (--jwt): SF_CONSUMER_KEY + SF_JWT_KEY, for orgs where you have created a
         Connected App or External Client App with the certificate. Pass the consumer keys in
         a JSON file: {"<org alias>": "<consumer key>"}; the key pair is generated in
         ~/.sfdevops/ (outside the repository) on first use.
     plus SF_USERNAME and SF_INSTANCE_URL.
  3. Stores the hub's credentials as repository secrets (HUB_AUTH_URL or HUB_JWT_KEY +
     HUB_CONSUMER_KEY, plus HUB_USERNAME and HUB_INSTANCE_URL), so workflows can call back.
  4. Asks once, with hidden input, for a GitHub token and stores it in the hub's Named
     Credential (External Credential GitHub_API_Credential, principal GitHub_PAT) so the hub
     can start workflows. With --set-gh-pat it also stores it as the GH_PAT repository secret.

Usage
  py sf-pipeline/scripts/bootstrap_secrets.py            (Windows)
  python3 sf-pipeline/scripts/bootstrap_secrets.py       (macOS / Linux)
  Options: --dry-run  --jwt --consumer-keys keys.json  --set-gh-pat  --skip-token
           --skip-environments  --reviewer <github-login>  --repo owner/name
"""

import argparse
import getpass
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import plan as planlib  # noqa: E402

EXT_CRED = "GitHub_API_Credential"
PRINCIPAL = "GitHub_PAT"
API = "v66.0"
KEY_DIR = os.path.join(os.path.expanduser("~"), ".sfdevops")


class Fail(Exception):
    pass


def log(msg):
    print(msg, flush=True)


def run(cmd, stdin=None, check=True):
    """Run a command (list), returning stdout. Secrets travel only through stdin, never argv."""
    proc = subprocess.run(cmd, input=stdin, capture_output=True, text=True, shell=False)
    if check and proc.returncode != 0:
        raise Fail(f"`{' '.join(cmd[:4])} ...` failed: {(proc.stderr or proc.stdout).strip()[:400]}")
    return proc.stdout


def exe(name):
    path = shutil.which(name) or shutil.which(name + ".cmd") or shutil.which(name + ".exe")
    if not path:
        raise Fail(f"`{name}` is not installed or not on PATH")
    return path


class Bootstrap:
    def __init__(self, args):
        self.a = args
        self.sf = exe("sf")
        self.gh = exe("gh")
        self.set_count = 0

    # ---------------------------------------------------------------- GitHub
    def repo(self):
        if self.a.repo:
            return self.a.repo
        out = run([self.gh, "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], check=False).strip()
        if not out:
            raise Fail("could not tell which GitHub repository this is; pass --repo owner/name")
        return out

    def gh_user(self):
        data = json.loads(run([self.gh, "api", "user"]))
        return data["login"], data["id"]

    def ensure_environment(self, repo, name, reviewer_id=None):
        body = {}
        if reviewer_id:
            body = {"reviewers": [{"type": "User", "id": reviewer_id}], "prevent_self_review": False}
        if self.a.dry_run:
            log(f"  [dry-run] would create/update GitHub Environment '{name}'" + (" with a required reviewer" if reviewer_id else ""))
            return
        run([self.gh, "api", "-X", "PUT", f"repos/{repo}/environments/{name}", "--input", "-"], stdin=json.dumps(body))
        log(f"  GitHub Environment '{name}' ready" + (" (required reviewer set)" if reviewer_id else ""))

    def set_secret(self, repo, name, value, env=None):
        where = f"environment '{env}'" if env else "the repository"
        if not value:
            raise Fail(f"refusing to set an empty {name} on {where}")
        if self.a.dry_run:
            log(f"  [dry-run] would set {name} on {where}")
            return
        cmd = [self.gh, "secret", "set", name, "--repo", repo]
        if env:
            cmd += ["--env", env]
        run(cmd, stdin=value)
        self.set_count += 1
        log(f"  set {name} on {where}")

    # ---------------------------------------------------------------- Salesforce
    def org(self, alias, verbose=False):
        cmd = [self.sf, "org", "display", "--target-org", alias, "--json"]
        if verbose:
            cmd.insert(3, "--verbose")
        out = run(cmd, check=False)
        try:
            data = json.loads(out)
        except ValueError:
            data = {}
        result = data.get("result") or {}
        if not result.get("username"):
            raise Fail(f"org alias '{alias}' is not logged in to the Salesforce CLI. Run: sf org login web --alias {alias}")
        return result

    def credentials_for(self, alias, keys):
        """Return (mode, dict of secret-name suffix -> value) for one org."""
        if self.a.dry_run:
            info = self.org(alias)
            return "dry-run", {"USERNAME": info["username"], "INSTANCE_URL": info.get("instanceUrl", "")}
        if self.a.jwt:
            if alias not in keys:
                raise Fail(f"--jwt needs a consumer key for '{alias}' in {self.a.consumer_keys}")
            info = self.org(alias)
            return "jwt", {"CONSUMER_KEY": keys[alias], "JWT_KEY": self.jwt_key_b64(),
                           "USERNAME": info["username"], "INSTANCE_URL": info.get("instanceUrl", "")}
        info = self.org(alias, verbose=True)
        url = info.get("sfdxAuthUrl")
        if not url:
            raise Fail(f"the CLI login for '{alias}' has no refresh token to share. Log in again with "
                       f"`sf org login web --alias {alias}` (or use --jwt).")
        return "auth-url", {"AUTH_URL": url, "USERNAME": info["username"], "INSTANCE_URL": info.get("instanceUrl", "")}

    def jwt_key_b64(self):
        import base64
        os.makedirs(KEY_DIR, exist_ok=True)
        key = os.path.join(KEY_DIR, "server.key")
        crt = os.path.join(KEY_DIR, "server.crt")
        if not os.path.isfile(key):
            openssl = exe("openssl")
            env = dict(os.environ, MSYS_NO_PATHCONV="1")
            subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", crt,
                            "-days", "3650", "-subj", "/CN=sfdevops-ci"], check=True, capture_output=True, env=env)
            log(f"  generated a JWT key pair in {KEY_DIR} (upload server.crt to each Connected App / External Client App)")
        with open(key, "rb") as fh:
            return base64.b64encode(fh.read()).decode("ascii")

    def store_named_credential(self, hub_alias, token):
        info = self.org(hub_alias, verbose=True)
        access, inst = info.get("accessToken"), info.get("instanceUrl")
        body = {"externalCredential": EXT_CRED, "principalName": PRINCIPAL, "principalType": "NamedPrincipal",
                "credentials": {"Token": {"value": token, "encrypted": True}}}
        url = f"{inst}/services/data/{API}/named-credentials/credential"
        for method in ("POST", "PUT"):
            req = urllib.request.Request(url, method=method, data=json.dumps(body).encode("utf-8"),
                                         headers={"Authorization": f"Bearer {access}", "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req) as resp:
                    log(f"  hub Named Credential token stored ({method} {resp.status})")
                    return True
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")[:300]
                if method == "POST" and exc.code in (400, 409):
                    continue  # already exists: update it instead
                log(f"  ! could not store the token through the API ({method} {exc.code}): {detail}")
        log("    Set it by hand instead: Setup > Named Credentials > External Credentials > GitHub API Credential >"
            " Principals > GitHub_PAT > Edit > Authentication Parameters > Token.")
        return False

    # ---------------------------------------------------------------- main flow
    def go(self):
        cfg = planlib.build_plan(planlib.load_yaml(os.path.join(ROOT, "sf-pipeline", "pipeline.config.yml")))
        repo = self.repo()
        login, uid = self.gh_user()
        reviewer_login = self.a.reviewer or login
        reviewer_id = uid if reviewer_login == login else json.loads(run([self.gh, "api", f"users/{reviewer_login}"]))["id"]
        log(f"Repository: {repo}   GitHub user: {login}   production reviewer: {reviewer_login}")
        keys = {}
        if self.a.jwt:
            keys = json.load(open(self.a.consumer_keys, encoding="utf-8"))

        prod = cfg["prod"]
        targets = []  # (alias, [gh environments])
        for o in cfg["source_orgs"]:
            targets.append((o["org_alias"], [o["gh_environment"]]))
        for e in cfg["envs"]:
            targets.append((e["org_alias"], [e["gh_environment"]]))
        targets.append((prod["org_alias"], [prod["validate_environment"], prod["deploy_environment"]]))
        missing = [t for t in targets if not t[0]]
        if missing:
            raise Fail("every source org, environment and production needs an org_alias in pipeline.config.yml")

        if not self.a.skip_environments:
            log("\n1. GitHub Environments")
            for alias, envs in targets:
                for env in envs:
                    self.ensure_environment(repo, env, reviewer_id if env == prod["deploy_environment"] else None)

        log("\n2. Org credentials (GitHub Environment secrets)")
        for alias, envs in targets:
            mode, creds = self.credentials_for(alias, keys)
            log(f"  {alias} ({mode}) -> {', '.join(envs)}")
            for env in envs:
                for suffix, value in creds.items():
                    if value:
                        self.set_secret(repo, f"SF_{suffix}", value, env)

        hub_alias = cfg["settings"]["hub_org_alias"]
        if hub_alias:
            log("\n3. Hub credentials (repository secrets)")
            mode, creds = self.credentials_for(hub_alias, keys)
            log(f"  {hub_alias} ({mode})")
            for suffix, value in creds.items():
                if value:
                    self.set_secret(repo, f"HUB_{suffix}", value)
        else:
            log("\n3. No hub org_alias in the config: GitHub-only mode, no HUB_* secrets.")

        if hub_alias and not self.a.skip_token and not self.a.dry_run:
            log("\n4. GitHub token for the hub (lets the hub start workflows)")
            log("   Fine-grained token on this repository: Actions RW, Contents RW, Pull requests RW, Metadata R, Workflows RW.")
            token = getpass.getpass("   Paste the token (input hidden, Enter to skip): ").strip()
            if token:
                self.store_named_credential(hub_alias, token)
                if self.a.set_gh_pat:
                    self.set_secret(repo, "GH_PAT", token)
                token = None
            else:
                log("   skipped")
        log(f"\nDone. {self.set_count} secret(s) set. No secret value was printed.")
        log("Next: run the 'sf-auth-check' workflow to prove every org signs in.")


def main(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dry-run", action="store_true", help="show what would happen; read no secrets, set nothing")
    p.add_argument("--jwt", action="store_true", help="JWT mode (needs --consumer-keys)")
    p.add_argument("--consumer-keys", default="", help='JSON file {"<org alias>": "<consumer key>"}')
    p.add_argument("--set-gh-pat", action="store_true", help="also store the GitHub token as the GH_PAT secret")
    p.add_argument("--skip-token", action="store_true", help="do not ask for the GitHub token")
    p.add_argument("--skip-environments", action="store_true", help="do not create GitHub Environments")
    p.add_argument("--reviewer", default="", help="production reviewer (default: you)")
    p.add_argument("--repo", default="", help="owner/name (default: this checkout's GitHub repository)")
    a = p.parse_args(argv)
    if a.jwt and not a.consumer_keys:
        p.error("--jwt needs --consumer-keys")
    try:
        Bootstrap(a).go()
    except Fail as exc:
        print(f"\nERROR: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
