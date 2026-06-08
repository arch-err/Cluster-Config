# to-build list

Backlog of cluster lifecycle tooling that should become declared, repeatable, and testable. A service without a lifecycle is a revenant; these are the exorcisms still owed.

## OIDC browser-login smoke harness

**Status:** to build

**Problem:** Current deployment smoke tests can prove an app serves HTTP and advertises OIDC, but they do not prove a full Pocket ID login round-trip works. Pingvin Share X exposed this rot: unauthenticated checks passed while real auth failed.

**Build idea:**

- Create a dedicated low-privilege Pocket ID test user for automation.
- Store its credentials/passkey-compatible test secret in SOPS, not plaintext.
- Add a Playwright + headless Chromium smoke test runner.
- Test flow:
  1. open target app URL, e.g. `https://pingvin.apps.home`
  2. click sign in / OIDC provider
  3. complete Pocket ID login as the automation user
  4. follow redirect back to the app
  5. assert authenticated UI/API state, not just `200 OK`
- Support per-app assertions so app-specific auth failures surface clearly.
- Run manually after new OIDC app deployments; later wire into a scheduled or post-sync check.

**Initial target:** Pingvin Share X OIDC login.

**Why this matters:** OIDC configuration is a chain of brittle undead parts — client registration, callback URL, issuer, secret, scopes, group/role mapping, cookies, and app-side auth toggles. Testing only the front door is not enough; the login ritual must complete.
