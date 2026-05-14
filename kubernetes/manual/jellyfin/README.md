# Jellyfin — manual UI steps

Jellyfin stores most user-facing config in its config PVC (`/config` mount,
backed by `jellyfin-config` PVC). The chart doesn't manage these — Jellyfin
writes them when you edit the admin UI. This file is the recipe for
re-creating them after a fresh install or a PVC wipe.

---

## 1. SSO login button on the login page

The `jellyfin-plugin-sso` (community plugin, repo
[9p4/jellyfin-plugin-sso](https://github.com/9p4/jellyfin-plugin-sso))
**does not auto-render a login button** — by design, login is initiated
by visiting `/sso/OID/start/<ProviderName>` directly. The standard pattern
is to drop an HTML form snippet into Jellyfin's **Login Disclaimer**
branding slot, which Jellyfin renders inline on the login page.

### Steps

1. Log in to Jellyfin as an admin (initially via local username/password
   created in the first-run wizard).
2. **Dashboard → General → Branding**
3. Paste the snippet below into the **Login Disclaimer** textbox.
4. Save. Reload the login page — the button appears below the username/
   password form.

### Snippet (paste into Login Disclaimer)

```html
<form action="/sso/OID/start/PocketID" method="post" id="sso-form">
  <button
    class="raised block emby-button button-submit"
    type="submit"
    style="margin-top:1em">
    Sign in with PocketID
  </button>
</form>
```

The `PocketID` in the action URL is the **Name of OID Provider** you set
when configuring the SSO-Auth plugin (Dashboard → Plugins → SSO-Auth).
Case-sensitive. Must match exactly.

### Optional — auto-redirect to SSO (with escape hatch)

Adds a tiny JS snippet inside the disclaimer that redirects the login
page to `/sso/OID/start/PocketID` automatically — unless `?local=1` is
in the query string. Drop-in replacement for the snippet above:

```html
<form action="/sso/OID/start/PocketID" method="post" id="sso-form">
  <button class="raised block emby-button button-submit" type="submit"
          style="margin-top:1em">
    Sign in with PocketID
  </button>
</form>
<script>
  (function() {
    // Escape hatch: append ?local=1 to URL to skip auto-redirect
    if (new URLSearchParams(window.location.search).has('local')) return;
    // Only trigger on the actual login page (Branding can render in other contexts)
    if (!/\/login\.html/.test(window.location.hash)) return;
    // Avoid double-redirect if already mid-SSO flow
    if (sessionStorage.getItem('sso-redirecting')) return;
    sessionStorage.setItem('sso-redirecting', '1');
    window.location.replace('/sso/OID/start/PocketID');
  })();
</script>
```

**Escape hatch — bookmark this for admin / recovery access:**

```
https://jellyfin.apps.home/web/index.html#!/login.html?local=1
```

This URL shows the local username/password form even with auto-redirect
on. Save the URL somewhere outside the cluster (Vaultwarden, sticky note,
etc.) in case SSO ever breaks.

**Caveats:**

- If `<script>` is sanitized out by a future Jellyfin version's branding
  filter, auto-redirect silently stops working — the form/button still
  works as a click-through. Worth testing after any Jellyfin upgrade.
- Mobile/TV native apps don't render Branding; they use `MediaBrowser`
  token auth against `/Users/AuthenticateByName`. Auto-redirect doesn't
  affect them.
- The `sessionStorage` guard prevents infinite redirects if the SSO flow
  ever bounces back to `/login.html` mid-handshake.

### Hide the local form entirely (most aggressive)

To remove the native username/password form completely instead of just
auto-redirecting past it, add this CSS to **Custom CSS Code**:

```css
/* Hide Jellyfin's native login form, leaving only the SSO button */
#loginPage form#loginForm { display: none !important; }
```

**Strongly discouraged** unless you've got a separate plan to recover
admin access (PVC edit, API). The escape hatch URL above will NOT save
you if the form is CSS-hidden — you'd need to edit branding via direct
DB/PVC access or hit the API to unset it. Auto-redirect is the better
default; native form stays in the DOM as a recovery path.

---

## 2. SSO-Auth plugin configuration

Repository for plugin install (add under **Dashboard → Plugins →
Repositories**):

```
https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json
```

After installing the plugin from **Catalog → Authentication → SSO
Authentication**, restart Jellyfin, then go to **Plugins → My Plugins →
SSO-Auth → Add OID Provider**:

| Field                              | Value                                             |
|------------------------------------|---------------------------------------------------|
| Name of OID Provider               | `PocketID` (case-sensitive — used in callback URL)|
| OID Endpoint                       | `https://auth.apps.home`                          |
| OID Client ID                      | `jellyfin`                                        |
| OID Secret                         | from `kubectl -n jellyfin get secret jellyfin-oidc-client -o jsonpath='{.data.client_secret}' \| base64 -d` |
| Enabled                            | ✅                                                |
| Enable Authorization by Plugin     | ✅ (auto-creates Jellyfin users on first OIDC)    |
| Enable All Folders                 | ✅                                                |
| Default Provider                   | ✅                                                |
| Default Username Claim             | `preferred_username`                              |
| OID Scopes                         | `openid profile email`                            |
| Disable HTTPS check                | ❌                                                |

Save.

Verify the callback URL in pocket-id includes:
`https://jellyfin.apps.home/sso/OID/redirect/PocketID`
(rendered into the `jellyfin-oidc-client` Secret by the platform chart's
`oidc:` block in `kubernetes/apps.yaml`).

---

## 3. First-run wizard quick-reference

If the `jellyfin-config` PVC is wiped, Jellyfin lands you on the
setup wizard. Walk through:

- Language: pick one.
- Create the first user: this becomes the bootstrap admin. **Save
  the password** — mobile/TV apps log in with this user, NOT pocket-id.
- Add libraries:
  - Movies → `/media/Movies` (Content type: Movies, TMDb metadata)
  - TV     → `/media/TV` (Content type: Shows, TVDb + TMDb)
  - YouTube → `/media/YouTube` (Content type: Mixed Content; **optional**
    — metube already has its own viewer)
- Metadata language: English (or whatever).
- **Allow remote connections**: ❌ (we're LAN-only behind the gateway).
- **Enable automatic port mapping**: ❌ (UPnP off — not desired here).

After wizard, do the SSO branding step (section 1) and the SSO-Auth
plugin config (section 2).
