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

### Optional — make OIDC the only path

To hide Jellyfin's native username/password form and force users through
SSO, add this CSS to the same Branding section's **Custom CSS Code** (or
the standalone Custom CSS plugin if you have it). Local admin login
still works at `/web/index.html#!/login.html?autoLaunch=0` style URL or
via API.

```css
/* Hide Jellyfin's native login form, leaving only the SSO button */
#loginPage form#loginForm { display: none !important; }
```

Caveat: if SSO breaks (plugin update, pocket-id misconfig, expired cert)
this leaves you locked out of the browser UI. Mobile/TV apps unaffected
(they use `MediaBrowser` token auth, not the web login). Keep an admin
account creds noted so you can re-enable the form via API or
PVC-direct-edit if needed. Recommend NOT hiding the form unless you have
that fallback plan.

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
