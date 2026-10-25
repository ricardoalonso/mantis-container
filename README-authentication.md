# OpenID Connect login

The image can log users in to MantisBT through an OpenID Connect identity
provider (IdP) such as Keycloak, Microsoft Entra ID, Okta or Authentik. It is
off by default and turned on with environment variables:

```sh
-e MANTIS_OIDC_ISSUER=https://sso.example.com/realms/mantis \
-e MANTIS_OIDC_CLIENT_ID=mantis \
-e MANTIS_OIDC_CLIENT_SECRET_FILE=/run/secrets/mantis-oidc-secret
```

This document explains how it works, how to set up the IdP, and why it is
built the way it is. The variable reference is in
[README-usage.md](README-usage.md#openid-connect).

## Contents

- [What users see](#what-users-see)
- [How it works](#how-it-works)
- [Accounts](#accounts)
- [Break-glass accounts](#break-glass-accounts)
- [Setting up the identity provider](#setting-up-the-identity-provider)
- [Running it](#running-it)
- [Security notes](#security-notes)
- [Limitations](#limitations)
- [Design decisions](#design-decisions)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)

## What users see

- Opening MantisBT sends them straight to the IdP's login page. There is no
  MantisBT username form in between.
- After logging in at the IdP they are back in MantisBT, on the page they
  originally asked for. The first time, their MantisBT account is created.
- Their account page has no password fields. It says the password is managed
  by single sign-on.
- **Logout** ends both the MantisBT session and the session at the IdP. The
  next visit asks for IdP credentials again.
- Administrators listed in `MANTIS_OIDC_LOCAL_USERS` (default `administrator`)
  log in with their MantisBT password at `/login_page.php?local=1`.

## How it works

Two parts, each doing what it is good at:

- **Apache, with [mod_auth_openidc](https://github.com/OpenIDC/mod_auth_openidc)**
  (the Rocky Linux package), handles the OpenID Connect protocol: the
  redirect to the IdP, PKCE, `state` and `nonce`, the code exchange, token
  signature and issuer checks, and logout at the IdP. It protects exactly one
  MantisBT URL, the login page of the plugin below, plus its own callback URL.
- **The `OidcAuth` MantisBT plugin**, shipped in the image, uses MantisBT's
  authentication API (`EVENT_AUTH_USER_FLAGS`). It turns the identity Apache
  hands over into a MantisBT session, creates and updates accounts, and keeps
  SSO users away from the password form.

```
 Browser                 Apache + mod_auth_openidc        OidcAuth plugin (PHP)       IdP
    |  GET /my_view_page.php     |                                |                    |
    |--------------------------->|  (not protected) ------------->| not logged in      |
    |<----------- 302 login_page.php --------------------------------|                  |
    |  GET /login_page.php       |------------------------------->| EVENT_CORE_READY:  |
    |<----------- 302 plugin.php?page=OidcAuth/login&return=... -----| skip the form    |
    |  GET plugin.php?page=OidcAuth/login                         |                    |
    |--------------------------->| protected: no session yet      |                    |
    |<-- 302 IdP /auth (code flow, PKCE S256, state, nonce) ------|                    |
    |-------------------------------------------------------------------------------->|
    |<---------------------------------- user logs in at the IdP; 302 /oidc/callback --|
    |  GET /oidc/callback?code=..|                                |                    |
    |--------------------------->| code -> tokens (back channel) ------------------->|
    |                            | validates id_token, sets session cookie            |
    |<-- 302 plugin.php?page=OidcAuth/login&return=... -----------|                    |
    |--------------------------->| REMOTE_USER=<username claim>   |                    |
    |                            | OIDC_CLAIM_email, _name ------>| find/create user,  |
    |                            |                                | auth_login_user()  |
    |<----------------- 302 login_cookie_test.php -> my_view_page.php -----------------|
```

After that, the user has an ordinary MantisBT session (the `MANTIS_STRING_COOKIE`
cookie). Other requests never go through mod_auth_openidc. The module's own
session is only used again at logout.

**Logout.** MantisBT's logout redirects to `oidc/callback?logout=<login page>`.
mod_auth_openidc clears its cookies and redirects to the IdP's
`end_session_endpoint` with `id_token_hint` and `post_logout_redirect_uri`.
The IdP ends its session and returns to `login_page.php`, which starts a new
login, so the IdP shows its login form.

**What the container generates.** Everything is generated on every start, so
changing a variable and restarting is enough:

| File | Contents |
|---|---|
| `/etc/httpd/conf.d/zz-oidc.conf` | `LoadModule`, the `OIDC*` directives and the two protected locations. Mode `0600`, because it contains the client secret. It is absent when OIDC is off, and the module is not loaded then. |
| `/etc/mantis/runtime_inc.php` | Force-enables the plugin (`$g_plugins_force_installed`) and sets `$g_plugin_OidcAuth_local_users`. Loaded at the end of `config_inc.php`. |

## Accounts

- **Matched by username.** The IdP claim named by
  `MANTIS_OIDC_USERNAME_CLAIM` (default `preferred_username`) is the MantisBT
  username. An existing MantisBT account with that username is used as is,
  including its access level, projects and history. So accounts are reused if
  you move from local or LDAP login to OIDC and the IdP usernames match.
- **Never matched by email.** Linking on email would let anyone who can set an
  unverified email at the IdP take over the MantisBT account that owns it.
- **Created on first login** with:
  - the IdP's `email` and `name` claims
  - MantisBT's default access level for new accounts,
    `$g_default_new_account_access_level` (`REPORTER` unless you change it in
    `config_inc.d/`)
  - a random password nobody knows

  No "set your password" email is sent.
- **Email and real name follow the IdP.** On every login, they are updated
  from the claims when those are present and different. If MantisBT rejects
  the new email (another account already uses it), the change is skipped and
  logged, and the login goes ahead.
- **Refused logins** show an explanation, with links to retry, log out of SSO
  or use the local form. They are also logged as `OidcAuth: ...` in the
  container log. A login is refused when:
  - the username is not valid for MantisBT
  - the account is disabled in MantisBT
  - the username is the anonymous account or a break-glass account
  - creating a new account fails because its email already belongs to
    another account
- **Access levels and projects are managed in MantisBT**, as before. IdP
  groups and roles are not mapped (see [Limitations](#limitations)).
- **API access.** SSO accounts cannot use passwords anywhere, which includes
  SOAP. REST and SOAP clients use API tokens, created by the user on
  *My Account → API Tokens*. These keep working unchanged.

## Break-glass accounts

`MANTIS_OIDC_LOCAL_USERS` (default `administrator`) lists accounts that keep
MantisBT's own login and **can never log in through the IdP**:

- They log in at `/login_page.php?local=1`: username, then password, as before.
- If the IdP returns one of these names, the login is refused. Otherwise anyone
  able to create a user called `administrator` at the IdP would become a
  MantisBT administrator.
- They are the way in when the IdP is down or misconfigured. Give them strong
  passwords, and keep the list short.
- `none` means no break-glass account. The only way back in is then to turn
  OIDC off and restart.

Typing any other username in the local form leads to the IdP, not to a password
prompt.

## Setting up the identity provider

What MantisBT needs from any IdP:

| Setting | Value |
|---|---|
| Client type | Confidential (client secret), authorization code flow. |
| PKCE | S256. The container always sends it; require it if your IdP allows. |
| Redirect URI | `<public MantisBT URL>/oidc/callback`, e.g. `https://bugs.example.com/oidc/callback`, or `https://example.com/mantis/oidc/callback` with `MANTIS_CONTEXT_PATH=/mantis`. |
| Post-logout redirect URI | `<public MantisBT URL>/login_page.php` |
| Scopes | `openid email profile` (configurable). |
| Claims in the ID token or userinfo | the username claim (`preferred_username`), `email`, `name`. |

Everything else can be off: implicit flow, password grant ("direct access"),
service accounts, front-channel logout.

### Keycloak

In the realm that holds your users:

1. **Clients → Create client.** Client type *OpenID Connect*, client ID
   `mantis`.
2. **Capability config.** *Client authentication* **on**. *Authentication
   flow*: only **Standard flow**. Turn off *Direct access grants*, *Implicit
   flow* and *Service accounts*.
3. **Login settings.**
   - *Root URL*: `https://bugs.example.com`
   - *Valid redirect URIs*: `https://bugs.example.com/oidc/callback`
   - *Valid post logout redirect URIs*: `https://bugs.example.com/login_page.php`
   - *Web origins*: empty.
4. **Advanced → Advanced settings.** *Proof Key for Code Exchange Code
   Challenge Method*: **S256**.
5. **Credentials.** Copy the *Client secret*. It becomes
   `MANTIS_OIDC_CLIENT_SECRET`.
6. **Client scopes.** The defaults (`basic`, `profile`, `email`, ...) provide
   `sub`, `preferred_username`, `name` and `email`. Nothing to add.
7. The issuer is `https://<keycloak>/realms/<realm>`. It is shown as `issuer`
   at `https://<keycloak>/realms/<realm>/.well-known/openid-configuration`.

Keycloak lower-cases usernames, so `preferred_username` matches MantisBT
usernames when those are lower case too. Rename MantisBT accounts that are not
lower case before switching.

If the realm was imported from Keycloak 24 or older, check that the client has
the **`basic`** client scope. Since Keycloak 25, `sub` comes from it, and
without it tokens lack `sub`.

### Other identity providers

- **Microsoft Entra ID.** Issuer `https://login.microsoftonline.com/<tenant-id>/v2.0`.
  Register a web application with the redirect URI above and create a client
  secret. Use `MANTIS_OIDC_USERNAME_CLAIM=preferred_username` (the UPN, e.g.
  `jdoe@example.com`) or `email`. Both are valid MantisBT usernames.
- **Okta, Authentik, Zitadel, Dex, ...** Any IdP with a discovery document at
  `<issuer>/.well-known/openid-configuration` works. Choose a username claim
  that is stable and unique.

## Running it

```sh
printf '%s' '<client secret>' | podman secret create mantis-oidc-secret -

podman run -d --pod mantis --name mantis-app \
  -e MANTIS_DB_HOST=127.0.0.1 -e MANTIS_DB_USER=mantis -e MANTIS_DB_PASSWORD=change-me \
  -e MANTIS_OIDC_ISSUER=https://sso.example.com/realms/mantis \
  -e MANTIS_OIDC_CLIENT_ID=mantis \
  --secret mantis-oidc-secret \
  -e MANTIS_OIDC_CLIENT_SECRET_FILE=/run/secrets/mantis-oidc-secret \
  -v mantis-config:/mantis/config -v mantis-attachments:/mantis/attachments \
  quay.io/ricardoalonsos/mantis:2.28.4
```

The startup log shows the result:

```
[entrypoint] OpenID Connect: issuer https://sso.example.com/realms/mantis, client mantis, username from preferred_username, local login for: administrator
```

- **Behind a reverse proxy** (TLS terminated in front of the container), set
  `HTTPD_TRUSTED_PROXIES` as described in README-usage.md. mod_auth_openidc
  then builds the redirect URI from `X-Forwarded-Proto` and `X-Forwarded-Host`.
  Make sure the proxy sends both, or preserves the `Host` header.
- **More than one replica.** Set the same `MANTIS_OIDC_CRYPTO_PASSPHRASE` (32
  characters or more) on all of them. The login state and session live in
  cookies encrypted with it, so a login can then finish on any replica. Without
  it, each container generates its own passphrase on every start.
- **Existing `config_inc.php`.** A `config_inc.php` generated by an older
  image, or written by hand, does not load `/etc/mantis/runtime_inc.php`. With
  OIDC on, the container then refuses to start, and the log shows the three
  lines to append.
- **Turning it off.** Remove `MANTIS_OIDC_ISSUER` and restart. Users who never
  had a local password then need one set by an administrator, or **Lost your
  password?** with email configured.

## Security notes

- **Only one URL is protected.** Apache requires an OIDC login only for
  `plugin.php?page=OidcAuth/login` and for `/oidc/callback`. The REST API,
  SOAP, static files and the health probes are untouched.
- **The identity is never taken from a header.** Apache passes it to PHP as
  server variables: `AUTH_TYPE`, `REMOTE_USER` and `OIDC_CLAIM_*`, with
  `OIDCPassClaimsAs environment`. A client cannot set those. The plugin
  refuses the request unless `AUTH_TYPE` is `openid-connect`. Requests that try
  to dodge Apache's URL match (for example `page=%4FidcAuth/login`) or that
  forge a `Remote-User` header get a 403. `oidc-test.sh` checks both.
- **Protocol hardening** is mod_auth_openidc's:
  - authorization code flow with PKCE S256
  - `state` and `nonce`
  - ID token signature, issuer, audience and expiry checks
  - `HttpOnly`, `SameSite=Lax` cookies, `Secure` over HTTPS
- **The client secret** can come from a file (`_FILE`). It is written only to
  `zz-oidc.conf`, mode `0600`, never to `zz-runtime.conf` or the log.
- **Use HTTPS for the issuer** in production. mod_auth_openidc logs a warning
  at startup when the discovery URL is plain HTTP.

## Limitations

- **No back-channel logout.** Logging out of the IdP elsewhere, or disabling
  the user at the IdP, does not end a MantisBT session that is already open.
  The MantisBT session lasts until the browser closes or the user logs out.
  "Remember me" is disabled for SSO users. To cut someone off immediately,
  disable the account in MantisBT as well.
- **Logout after a working day.** mod_auth_openidc's session, needed to pass
  `id_token_hint` at logout, lasts 8 hours. Logging out of MantisBT later than
  that still ends the MantisBT session. The IdP may then ask "do you want to
  log out?", or keep its own session.
- **No group or role mapping.** Access levels and project membership stay in
  MantisBT. New accounts get `$g_default_new_account_access_level`.
- **Cookie size.** The session cookie carries the ID, access and refresh
  tokens: about 6 KB with Keycloak's defaults, split into two cookies. Very
  large tokens (users in hundreds of groups, with group claims) could reach
  Apache's 8 KB limit on the `Cookie` header. Trim the token at the IdP, or
  switch to a server-side session with a drop-in containing
  `OIDCSessionType server-cache`. That works only with a single replica, or
  with sticky sessions.
- **One IdP.** There is no IdP selection page.
- **The anonymous account** (`$g_allow_anonymous_login`) is not combined with
  SSO: the login page always goes to the IdP.

## Design decisions

**Apache speaks OIDC, not PHP.** mod_auth_openidc is a maintained, widely
deployed module, packaged and patched by the distribution. OIDC libraries
inside MantisBT plugins are small, rarely updated, and would add one more
component to track for security fixes. Doing the protocol in Apache also keeps
it out of the PHP request path for every request but the login.

**A plugin on MantisBT's authentication API, not `BASIC_AUTH` or `HTTP_AUTH`.**
MantisBT 2.28 has no OIDC login method. Its documentation lists `MD5`, `LDAP`,
`BASIC_AUTH` and `HTTP_AUTH`, and says nothing about OpenID Connect. The
"trust the web server" methods do not fit:

- `BASIC_AUTH` reads the user from `REMOTE_USER`, but still shows MantisBT's
  login form, which is skipped only for `HTTP_AUTH`. It also takes the password
  from `PHP_AUTH_PW` and checks it against the stored one. OIDC never provides
  a password, so existing users would fail that check, and new ones would get
  `md5('')` as their password.
- `HTTP_AUTH` makes MantisBT send its own Basic-auth challenge (`401`), and
  its documentation section is literally "TODO".

Making either work would have needed a patch to MantisBT core, carried and
re-generated for every release. The authentication API
(`EVENT_AUTH_USER_FLAGS`, the mechanism of MantisBT's SampleAuth example) does
the job without touching core. `login_method` stays `MD5`, so break-glass
accounts keep working.

**Skip the username form.** For users who are not logged in, MantisBT never
consults the plugin about the login page. The plugin therefore hooks
`EVENT_CORE_READY` and redirects `login_page.php` to the OIDC login, unless the
local form is asked for (`?local=1`), or a failed local login is coming back
(`error`, `username`).

**`preferred_username` as the username.** It is human-readable, and it matches
how MantisBT usernames usually look, so existing accounts are reused. It is
configurable. `sub` is the most stable choice but unreadable, and `email`
changes more often than usernames do.

**Break-glass accounts, refused through SSO.** They keep access while the IdP
is down. Refusing those names through SSO removes the obvious escalation
(registering `administrator` at the IdP).

**Configured on every start, like the Apache settings.** The Apache half has to
be regenerated on every start anyway, so the MantisBT half is generated at the
same time, into `/etc/mantis/runtime_inc.php`. This keeps the two halves
consistent. The plugin is force-enabled from configuration
(`$g_plugins_force_installed`), so there is no database step, and it cannot be
uninstalled by accident from *Manage Plugins*. `config_inc.php` (generated
once, owned by the user) only needs to load that file, and it loads it last,
so the environment wins.

**Session in cookies (`client-cookie:store_id_token`).** It needs no shared
cache between replicas. `store_id_token` is required, because without the
ID token logout cannot send `id_token_hint`, and the IdP then shows a
confirmation page instead of logging out.

**mod_auth_openidc is not loaded when OIDC is off.** The package's
`conf.modules.d` file is removed at build time. The generated `zz-oidc.conf`
loads the module only when it is used.

**Accounts matched by username, never by email**, for the takeover reason
explained under [Accounts](#accounts).

## Testing

Two scripts, both run against the built image:

- **`./smoke-test.sh`** needs no IdP. It checks that OIDC is:
  - off by default, with the module not loaded
  - rendered and accepted by Apache when configured, with the secret only in
    a `0600` file and the plugin enabled
  - checked for invalid values
  - refused (the container stops) when an old `config_inc.php` does not load
    the runtime file
- **`./oidc-test.sh`** runs the real browser flow with curl against an IdP:
  redirects, the IdP's login form and cookies. It checks:
  - the redirect to the IdP (code flow, PKCE S256, redirect URI)
  - account creation from the claims, and the default access level
  - that SSO accounts have no password
  - refusal of break-glass names through SSO
  - local login for `administrator`
  - that the login page cannot be reached without Apache, and forged headers
  - REST and probes untouched
  - logout at the IdP with `id_token_hint`
  - a second login reusing the account

  ```sh
  OIDC_ISSUER=http://localhost:8081/realms/mantis \
  OIDC_CLIENT_SECRET=... OIDC_TEST_PASSWORD=... OIDC_LOCAL_TEST_PASSWORD=... \
  ./oidc-test.sh
  ```

  The IdP needs the `mantis` client, with redirect URI
  `http://localhost:18090/oidc/callback` and post-logout URI
  `http://localhost:18090/login_page.php`, plus two users: `mantis-alice`
  (email `alice@example.test`, name *Alice Tester*) and `mantis-breakglass`.
  All names can be overridden; see the top of the script. For an IdP on this
  machine's `localhost`, the script forwards the container's `localhost:<port>`
  to it, so the browser and the container see the same issuer URL.

### Reference test setup (Keycloak 26.2, realm `mantis`)

This is the configuration `oidc-test.sh` was run against:

- **Client `mantis`:**
  - confidential (client secret), standard flow only
  - direct access grants, implicit flow, service accounts and front-channel
    logout off
  - PKCE `S256`
  - root URL `http://localhost:18090`
  - redirect URI `http://localhost:18090/oidc/callback`
  - post-logout redirect URI `http://localhost:18090/login_page.php`
  - no web origins
  - default client scopes left as Keycloak creates them (`web-origins`, `acr`,
    `roles`, `profile`, `basic`, `email`)
- **User `mantis-alice`:** email `alice@example.test` (verified), first name
  *Alice*, last name *Tester*, password set, no required actions.
- **User `mantis-breakglass`:** email `breakglass@example.test` (verified),
  *Break Glass*, password set. Listed in `MANTIS_OIDC_LOCAL_USERS` by the test,
  to prove such names are refused.

## Troubleshooting

**The container stops with "does not load /etc/mantis/runtime_inc.php".** Your
`config_inc.php` predates OIDC support. Append the lines printed in the error.

**"Single sign-on failed: ... the web server did not authenticate the
request".** The plugin's login page was reached without mod_auth_openidc in
front. Check that `zz-oidc.conf` exists
(`podman exec mantis-app ls /etc/httpd/conf.d/`). If MantisBT is behind
another web server that rewrites URLs, make sure it passes
`plugin.php?page=OidcAuth/login` through unchanged.

**The IdP says "Invalid parameter: redirect_uri".** The redirect URI the
container sent does not match the client's list. Look at the `redirect_uri`
parameter in the browser's address bar on the IdP page. Behind a proxy, set
`HTTPD_TRUSTED_PROXIES` so it is built from the public URL, and make sure
`MANTIS_CONTEXT_PATH` matches the public path.

**Apache logs "no state cookie found" or "state has expired".** The login took
more than 5 minutes, the browser blocks cookies, or, with several replicas,
`MANTIS_OIDC_CRYPTO_PASSPHRASE` differs between them.

**Login fails with an issuer mismatch in the Apache log.** The container and the browser see the
IdP under different URLs. The issuer in `MANTIS_OIDC_ISSUER` must be the
IdP's public URL, reachable from the container as well. For Keycloak, set
`KC_HOSTNAME` so the issuer does not depend on how Keycloak is reached.

**A user gets "already used by another MantisBT account".** Their IdP email
belongs to a different MantisBT username. Rename that account to the IdP
username, which then reuses it with its history, or change its email.

**Locked out (IdP down, or a misconfiguration).** Log in as a break-glass
account at `/login_page.php?local=1`. If there is none, remove
`MANTIS_OIDC_ISSUER` and restart.

**More detail.** `-e HTTPD_LOG_LEVEL="warn auth_openidc:debug"` logs every
step of the protocol. The plugin's own messages start with `OidcAuth:`.
