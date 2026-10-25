# MantisBT container image: usage

[MantisBT](https://mantisbt.org/) on Apache 2.4 and PHP-FPM, on Rocky Linux 9.
It includes local patches for attachment storage and LDAP user creation, and
optional single sign-on through OpenID Connect.

```
quay.io/ricardoalonsos/mantis:<mantis-version>     e.g. :2.28.4
```

This guide is also inside the image, with its companion on single sign-on
(`README-authentication.md`):

```sh
podman run --rm quay.io/ricardoalonsos/mantis:2.28.4 cat /usr/share/doc/mantis-container/README-usage.md
```

## Contents

- [Quick start](#quick-start)
- [Ports, volumes and user](#ports-volumes-and-user)
- [First installation](#first-installation)
- [Configuration reference](#configuration-reference)
- [Single sign-on (OpenID Connect)](#openid-connect)
- [Customising beyond the variables](#customising-beyond-the-variables)
- [Plugins](#plugins)
- [HTTPS and reverse proxies](#https-and-reverse-proxies)
- [Secrets](#secrets)
- [Upgrading MantisBT](#upgrading-mantisbt)
- [Operations](#operations)
- [Health checks, Kubernetes and OpenShift](#health-checks-kubernetes-and-openshift)
- [Troubleshooting](#troubleshooting)
- [Changes from earlier images](#changes-from-earlier-images)

## Quick start

A MariaDB database and MantisBT in one pod:

```sh
podman pod create --name mantis -p 8080:8080

podman run -d --pod mantis --name mantis-db \
  -e MARIADB_ROOT_PASSWORD=change-me-root \
  -e MARIADB_DATABASE=bugtracker \
  -e MARIADB_USER=mantis \
  -e MARIADB_PASSWORD=change-me \
  -v mantis-db:/var/lib/mysql \
  docker.io/library/mariadb:11

podman run -d --pod mantis --name mantis-app \
  -e MANTIS_DB_HOST=127.0.0.1 \
  -e MANTIS_DB_USER=mantis \
  -e MANTIS_DB_PASSWORD=change-me \
  -e MANTIS_ADMINISTRATION_ENABLED=true \
  -e PHP_DATE_TIMEZONE=America/Sao_Paulo \
  -v mantis-config:/mantis/config \
  -v mantis-attachments:/mantis/attachments \
  quay.io/ricardoalonsos/mantis:2.28.4
```

Then open `http://localhost:8080/admin/install.php` to create the
database schema, and log in as `administrator` / `root`. **Change that password
immediately.** Then
[turn the admin pages off again](#first-installation).

## Ports, volumes and user

| | |
|---|---|
| `8080/tcp` | HTTP. |
| `8443/tcp` | HTTPS. Self-signed by default; see [HTTPS](#https-and-reverse-proxies). |
| `/mantis/config` | **Volume.** `config_inc.php` and any other MantisBT configuration. |
| `/mantis/attachments` | **Volume.** Uploaded files, when attachments are stored on disk (the default). |
| `/mantis/plugins` | **Volume.** MantisBT's plugin directory. See [Plugins](#plugins). |
| `/mantis/conf.d/{php,php-fpm,httpd}` | Optional mount points for [configuration drop-ins](#drop-in-files). |
| `/mantis/entrypoint.d` | Optional mount point for [startup hooks](#startup-hooks). |

The container runs as `apache` (uid 48, gid 0). Named volumes work as they are.
**Bind-mounted directories** must be writable by uid 48. With rootless podman:

```sh
podman unshare chown -R 48:0 ./config ./attachments ./plugins
podman run ... -v ./config:/mantis/config:Z -v ./attachments:/mantis/attachments:Z \
  -v ./plugins:/mantis/plugins:Z ...
```

MantisBT is served at `/` by default. To serve it under a sub-path instead,
set `MANTIS_CONTEXT_PATH`, e.g. `-e MANTIS_CONTEXT_PATH=/mantis`: MantisBT is
then at `/mantis/`, `/` redirects there, and nothing else is served apart from
`/healthz.php`. The URLs below assume the default; prefix them with the context
path if you set one.

## First installation

The admin pages (`/admin/`) can install and upgrade the database. For
that reason they are **disabled by default** and should be enabled only while
you need them.

1. **Write the configuration.** Choose one:
   - **From environment variables (recommended).** Set `MANTIS_DB_HOST` and the
     other [MantisBT variables](#mantisbt). On first start the container writes
     `config_inc.php` into the config volume.
   - **Use the web installer.** Leave `MANTIS_DB_HOST` unset. The installer
     asks for the database details and writes `config_inc.php` itself.
   - **Use your own file.** Put `config_inc.php` in the config volume. The
     container never overwrites it.
2. **Create the schema.** Start with `MANTIS_ADMINISTRATION_ENABLED=true` and
   open `/admin/install.php`.
3. **Lock it down.** Recreate the container without
   `MANTIS_ADMINISTRATION_ENABLED` (or set it to `false`). Log in and change the
   `administrator` password.

> **`config_inc.php` is generated only once.** Once it exists, the `MANTIS_*`
> settings below are ignored and the file on the volume is the source of
> truth. To change a setting, edit the file. To start over from the environment
> variables, delete the file and restart the container.

## Configuration reference

All variables are optional. An empty value (`-e VAR=`) means "use the default".
Every value is checked at startup. An invalid one stops the container with a
message saying which variable is wrong and why, rather than starting with a
broken configuration.

Booleans accept `true/false`, `yes/no`, `on/off` and `1/0`. Sizes use PHP's
shorthand: `512K`, `64M`, `1G` (not `64MB`).

### MantisBT

These variables apply at **every start**:

| Variable | Default | Description |
|---|---|---|
| `MANTIS_CONTEXT_PATH` | `/` | URL path MantisBT is served at, e.g. `/mantis`. Leading and trailing slashes are optional. When it is not `/`, requests to `/` redirect to it. |
| `MANTIS_ADMINISTRATION_ENABLED` | `false` | Serve `admin/` for installing or upgrading. Turn it off afterwards. |
| `MANTIS_CONFIG_FOLDER` | `/mantis/config/` | Where MantisBT looks for `config_inc.php`. Change it only if you mount the config somewhere else. |
| `MANTIS_PLUGINS` | | Plugin archives to download and install, each `<URL>#sha256=<checksum>`, separated by spaces. Also `_FILE`. See [Plugins](#plugins). |

These variables are used **only when `config_inc.php` is generated** (see
[First installation](#first-installation)). Generation happens only when
`MANTIS_DB_HOST` is set and no `config_inc.php` exists yet.

| Variable | Default | Description |
|---|---|---|
| `MANTIS_DB_HOST` | | Database host, or `host:port`. Setting it enables generation. |
| `MANTIS_DB_TYPE` | `mysqli` | `mysqli` (MySQL/MariaDB) or `pgsql` (PostgreSQL). |
| `MANTIS_DB_NAME` | `bugtracker` | Database name. |
| `MANTIS_DB_USER` | | Database user. Required. |
| `MANTIS_DB_PASSWORD` | | Database password. Also `_FILE`. |
| `MANTIS_CRYPTO_MASTER_SALT` | random | At least 16 characters. When unset, a random one is generated and stored in `config_inc.php`. Also `_FILE`. |
| `MANTIS_PATH` | auto-detected | Public URL, e.g. `https://bugs.example.com/` (include `MANTIS_CONTEXT_PATH` if you set one). Set it when MantisBT is behind a proxy, so links in emails are correct. |
| `MANTIS_FILE_UPLOAD_METHOD` | `DISK` | `DISK` (files go in `/mantis/attachments`) or `DATABASE`. |
| `MANTIS_UPLOAD_FOLDER` | `/mantis/attachments/` | Folder for attachments stored on disk. |
| `MANTIS_FILE_UPLOAD_SUBDIRECTORY_DEPTH` | | Store attachments in subdirectories (patched feature). `1` is a sensible value for large installations. |
| `MANTIS_FILE_UPLOAD_SUBDIRECTORY_WIDTH` | | Characters per subdirectory level. MantisBT's default is `2`. |
| `MANTIS_SMTP_HOST` | | SMTP server. **When unset, email notifications are turned off**, because the container has no local mail server. |
| `MANTIS_SMTP_PORT` | `587` | SMTP port. |
| `MANTIS_SMTP_CONNECTION_MODE` | `tls` | `tls` (STARTTLS), `ssl` (implicit TLS, usually port 465) or `none`. |
| `MANTIS_SMTP_USERNAME` | | SMTP user. Also `_FILE`. |
| `MANTIS_SMTP_PASSWORD` | | SMTP password. Also `_FILE`. |
| `MANTIS_EMAIL_FROM` | MantisBT default | Sender address of notifications. |
| `MANTIS_EMAIL_FROM_NAME` | MantisBT default | Sender name. |
| `MANTIS_EMAIL_WEBMASTER` | MantisBT default | Webmaster address shown to users. |
| `MANTIS_EMAIL_RETURN_PATH` | MantisBT default | Address that receives bounces. |
| `MANTIS_LDAP_SERVER` | | e.g. `ldap://ldap.example.com` or `ldaps://...`. Setting it switches login to LDAP. |
| `MANTIS_LDAP_ROOT_DN` | | Search base, e.g. `dc=example,dc=com`. |
| `MANTIS_LDAP_ORGANIZATION` | | Optional extra search filter, e.g. `(memberOf=cn=mantis,ou=groups,dc=example,dc=com)`. |
| `MANTIS_LDAP_BIND_DN` | | Account used to search. Also `_FILE`. |
| `MANTIS_LDAP_BIND_PASSWORD` | | Its password. Also `_FILE`. |
| `MANTIS_LDAP_UID_FIELD` | `uid` | Login attribute. Use `sAMAccountName` for Active Directory. |
| `MANTIS_LDAP_PROTOCOL_VERSION` | `3` | LDAP protocol version. |
| `MANTIS_LDAP_USE_STARTTLS` | `true` | Use STARTTLS on `ldap://`. Set it to `false` with `ldaps://`. |
| `MANTIS_LDAP_FOLLOW_REFERRALS` | `false` | Follow referrals. Keep it `false` for Active Directory. |
| `MANTIS_LDAP_USE_EMAIL` | `false` | Take users' email addresses from LDAP. |
| `MANTIS_LDAP_USE_REALNAME` | `false` | Take users' real names from LDAP. |

For any MantisBT setting not listed here, see
[`config_inc.d/`](#mantisbt-settings-config_incd).

### OpenID Connect

Single sign-on through an OpenID Connect identity provider (Keycloak, Entra ID,
Okta...). Off unless `MANTIS_OIDC_ISSUER` is set. Unlike the variables above,
these apply at **every start**, so changing one and restarting is enough.
How it works, how to set up the identity provider, and the design decisions:
[README-authentication.md](README-authentication.md).

| Variable | Default | Description |
|---|---|---|
| `MANTIS_OIDC_ISSUER` | | Issuer URL, e.g. `https://sso.example.com/realms/mantis` (Keycloak). `<issuer>/.well-known/openid-configuration` must exist. Setting it turns single sign-on on. |
| `MANTIS_OIDC_CLIENT_ID` | | Client ID registered at the identity provider. Required. |
| `MANTIS_OIDC_CLIENT_SECRET` | | Its client secret. Required. Also `_FILE`. Must not contain `"`, `\` or `$`. |
| `MANTIS_OIDC_USERNAME_CLAIM` | `preferred_username` | Claim that becomes the MantisBT username. Existing accounts with that username are reused; others are created on first login. |
| `MANTIS_OIDC_SCOPES` | `openid email profile` | Scopes requested. Must include `openid`. |
| `MANTIS_OIDC_LOCAL_USERS` | `administrator` | Comma-separated break-glass accounts: they keep the MantisBT password login at `/login_page.php?local=1` and are refused through single sign-on. `none` for no exception. |
| `MANTIS_OIDC_CRYPTO_PASSPHRASE` | random per start | Encrypts the login cookies, at least 32 characters. **Set the same value on every replica** when running more than one. Also `_FILE`. |

At the identity provider, register a confidential client with the redirect URI
`<public URL>/oidc/callback` and the post-logout redirect URI
`<public URL>/login_page.php`:

```sh
-e MANTIS_OIDC_ISSUER=https://sso.example.com/realms/mantis \
-e MANTIS_OIDC_CLIENT_ID=mantis \
-e MANTIS_OIDC_CLIENT_SECRET_FILE=/run/secrets/mantis-oidc-secret
```

Behind a reverse proxy, also set `HTTPD_TRUSTED_PROXIES` (see
[reverse proxies](#behind-a-reverse-proxy)): the redirect URI is then built from
the public scheme and host.

A `config_inc.php` written by hand, or generated by an earlier image, does not
load the file these settings are written to. The container then refuses to
start with OIDC on, and prints the three lines to add to it.

### PHP

| Variable | Default | Description |
|---|---|---|
| `PHP_UPLOAD_MAX_FILESIZE` | `4M` | Largest single attachment. |
| `PHP_POST_MAX_SIZE` | 4 × upload size | Largest request. MantisBT sends every file attached to an issue in one request, so this must be at least the upload size. |
| `PHP_MEMORY_LIMIT` | `256M` | Per PHP worker. `-1` means no limit. |
| `PHP_MAX_EXECUTION_TIME` | `30` | Seconds of PHP execution per request. |
| `PHP_MAX_INPUT_TIME` | `60` | Seconds allowed to receive the request, including uploads. Raise it for large uploads over slow links. |
| `PHP_MAX_INPUT_VARS` | `1000` | Raise it if very large forms (many custom fields, bulk actions) lose data. |
| `PHP_DATE_TIMEZONE` | `$TZ`, else `UTC` | e.g. `America/Sao_Paulo`. Checked against PHP's timezone list. |
| `PHP_DISPLAY_ERRORS` | `Off` | `On` shows errors in the page. Use it only for debugging. |
| `PHP_ERROR_REPORTING` | `E_ALL & ~E_DEPRECATED` | Which errors are logged. |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `On` | `Off` is slightly faster, but then edits to `config_inc.php` need a container restart to take effect. |
| `PHP_INI_<key>` | | Any other php.ini setting. See [below](#any-phpini-or-php-fpm-setting). |

The maximum attachment size MantisBT shows to users is the smaller of
`PHP_UPLOAD_MAX_FILESIZE` and `PHP_POST_MAX_SIZE`.

### PHP-FPM

| Variable | Default | Description |
|---|---|---|
| `PHP_FPM_PM` | `dynamic` | `dynamic`, `static` or `ondemand`. |
| `PHP_FPM_MAX_CHILDREN` | `20` | Maximum PHP workers, so the maximum number of PHP requests handled at once. |
| `PHP_FPM_START_SERVERS` | min(4, max spare) | `dynamic` only. |
| `PHP_FPM_MIN_SPARE_SERVERS` | start ÷ 2 | `dynamic` only. |
| `PHP_FPM_MAX_SPARE_SERVERS` | min(8, max children) | `dynamic` only. |
| `PHP_FPM_PROCESS_IDLE_TIMEOUT` | `10s` | `ondemand` only. |
| `PHP_FPM_MAX_REQUESTS` | `500` | Recycle a worker after this many requests. `0` means never. |
| `PHP_FPM_REQUEST_TERMINATE_TIMEOUT` | `PHP_MAX_EXECUTION_TIME` | Wall-clock limit per request. It also stops requests stuck waiting on the database or the network, which `max_execution_time` does not count. |
| `PHP_FPM_POOL_<key>` | | Any other pool setting. See [below](#any-phpini-or-php-fpm-setting). |

**Sizing.** In the worst case PHP uses `PHP_FPM_MAX_CHILDREN` ×
`PHP_MEMORY_LIMIT` of memory. A typical MantisBT request uses 20–60 MB, far
below the limit. The container logs a warning at startup if that worst case
exceeds its memory limit (`--memory`).

### Apache

| Variable | Default | Description |
|---|---|---|
| `HTTPD_SERVER_NAME` | `localhost` | Public hostname. Also used as the name in the self-signed certificate. |
| `HTTPD_REQUEST_TIMEOUT` | `60` | Seconds. Also limits how long Apache waits for PHP. Keep it at or above `PHP_FPM_REQUEST_TERMINATE_TIMEOUT`. |
| `HTTPD_LOG_LEVEL` | `warn` | e.g. `info`, `debug`, `warn ssl:info`. |
| `HTTPD_TRUSTED_PROXIES` | | Proxy addresses or CIDR ranges, separated by spaces or commas. See [reverse proxies](#behind-a-reverse-proxy). |
| `HTTPD_REMOTEIP_HEADER` | `X-Forwarded-For` | The header that carries the client address. |
| `HTTPD_STATUS_ALLOW` | `local` | Who may see `/server-status` and `/php-status`: `local`, `none`, `all`, or IP addresses / CIDR ranges (localhost is always included). |
| `HTTPD_ENABLE_HTTPS` | `true` | `false` turns the 8443 listener off completely. |
| `HTTPD_TLS_CERT_FILE` | | Path to your certificate inside the container. Include the intermediate certificates in this file. |
| `HTTPD_TLS_KEY_FILE` | | Path to the matching private key. |

## Customising beyond the variables

Use these four mechanisms for anything the variables above do not cover. None
of them requires rebuilding the image.

### Any php.ini or PHP-FPM setting

Name the variable `PHP_INI_` or `PHP_FPM_POOL_` followed by the setting name.
A dot in the setting name is written as `__` (two underscores), because a
variable name cannot contain a dot. Setting names are case-sensitive.

```sh
-e PHP_INI_session__gc_maxlifetime=7200                # session.gc_maxlifetime = 7200
-e PHP_INI_realpath_cache_size=4M                      # realpath_cache_size = 4M
-e PHP_FPM_POOL_pm__status_listen=127.0.0.1:9001       # pm.status_listen = 127.0.0.1:9001
```

These are applied after the named variables above, so they win if both set the
same thing.

### Drop-in files

Mount a directory, or individual files, at:

| Directory | Files | Copied to |
|---|---|---|
| `/mantis/conf.d/php/` | `*.ini` | `/etc/php.d/` |
| `/mantis/conf.d/php-fpm/` | `*.conf` | `/etc/php-fpm.d/`. Start the file with `[www]` to change the pool. |
| `/mantis/conf.d/httpd/` | `*.conf` | `/etc/httpd/conf.d/` |

Drop-ins are applied last, so they override everything else. They are copied
again on every start, and a file you remove is removed from the container on
the next restart.

```sh
mkdir -p conf.d/httpd
cat > conf.d/httpd/limits.conf <<'EOF'
LimitRequestBody 104857600
EOF
podman run ... -v ./conf.d:/mantis/conf.d:ro,Z ...
```

### MantisBT settings: `config_inc.d/`

A generated `config_inc.php` loads every `*.php` file in a `config_inc.d/`
directory next to it, in name order. This keeps your own settings separate from
the generated file:

```sh
podman exec mantis-app mkdir -p /mantis/config/config_inc.d
podman cp 10-branding.php mantis-app:/mantis/config/config_inc.d/
```

```php
<?php
# 10-branding.php
$g_window_title = 'ACME Bugs';
$g_allow_signup = OFF;
```

If you wrote `config_inc.php` yourself, you can add the same `foreach( glob(...) )`
block to it, or simply edit your file.

### Startup hooks

Executable or not, every `*.sh` file in `/mantis/entrypoint.d/` runs with bash,
in name order, after the configuration is written and before the configuration
check. They run as `apache`. **A hook that fails stops the container.**

```sh
# entrypoint.d/10-wait-for-db.sh
for i in $(seq 1 30); do
  php -r 'exit(@fsockopen("127.0.0.1", 3306) ? 0 : 1);' && exit 0
  sleep 1
done
echo "database not reachable" >&2; exit 1
```

### What happens at startup

1. PHP, PHP-FPM and Apache settings are validated and written, and so are the
   OpenID Connect settings. Drop-ins are copied.
2. `config_inc.php` is generated, if needed.
3. `/mantis/plugins` is filled: the image's own plugins and the `MANTIS_PLUGINS`
   downloads.
4. The admin pages are enabled or disabled.
5. Hooks in `/mantis/entrypoint.d` run.
6. The configuration is checked (PHP, `php-fpm -t`, `httpd -t`). Any error
   stops the container, and the log shows why.
7. PHP-FPM and Apache start. If either one exits, the container exits with a
   non-zero status, so a restart policy (`--restart on-failure`) recovers it.

## Plugins

MantisBT's plugin directory is the `/mantis/plugins` volume, so plugins are
added without rebuilding the image. It holds three kinds of plugin:

| Kind | Where it comes from | On every start |
|---|---|---|
| **The image's own** | MantisBT's (`MantisCoreFormatting`, `MantisGraph`, `Gravatar`, `XmlImportExport`) and `OidcAuth` | Replaced with the image's copy, so they always match the MantisBT version. Their names are reserved. |
| **Downloaded** | `MANTIS_PLUGINS` | Installed again from the archive. Removed when the archive leaves the list. |
| **Your own** | Any other folder you put in the volume | Never touched. |

Putting a plugin's files in place does not enable it. Enable it in
**Manage → Manage Plugins**, as with any MantisBT installation. The database
remembers it from then on.

### Copying a plugin in

A plugin is a folder whose name matches its main file, e.g. `Snippets/Snippets.php`.
Copy it into the volume of a running container. It appears in Manage Plugins
at once, with no restart:

```sh
podman cp ./Snippets mantis-app:/mantis/plugins/
```

To manage the folder from the host instead, bind-mount a directory (writable by
uid 48, see [above](#ports-volumes-and-user)) at `/mantis/plugins`. The
container adds the image's plugins to it on start.

### Downloading at startup: `MANTIS_PLUGINS`

List the archives (`.tar.gz`, `.tgz` or `.zip`) with the
SHA-256 of each. An archive may hold one plugin or several, at any depth. A
plugin is found by its `<Name>.php` declaring `class <Name>Plugin`, and is
installed as `/mantis/plugins/<Name>`, whatever the folder in the archive is
called. For example, GitHub's `Snippets-2.6.0/` becomes `Snippets`.

```sh
-e MANTIS_PLUGINS="\
https://github.com/mantisbt-plugins/source-integration/archive/refs/tags/v2.9.2.tar.gz#sha256=30b068bd041f069ab0259604c0c8bf348cba97cd192ab466f60aad9708f85fc4 \
https://github.com/mantisbt-plugins/Snippets/archive/refs/tags/v2.6.0.zip#sha256=661b11003d82715bfc9a7948f2e6bf06249007038d36315f95833c705f362d77"
```

Get the checksum with `curl -sL <URL> | sha256sum`.

- **The checksum is required.** A download that does not match stops the
  container. Pin a release, not a branch: a branch archive changes, and its
  checksum with it.
- **Downloaded once.** Archives are cached in the volume by checksum, as
  `.archive-<sha256>` files. With a persistent volume, later starts do not need the network,
  or even the URL to be up. The first start does: an unreachable URL stops
  the container.
- **URLs:** `https://`, `http://` (the checksum protects the content) and
  `file://`, for an archive mounted into the container.
- **Private URLs** (tokens in the URL): put the list in a file and use
  `MANTIS_PLUGINS_FILE`. Entries may then be on separate lines.
- **Removing a plugin.** Uninstall it in Manage Plugins first, then take it
  out of the list and restart. Otherwise MantisBT lists it as missing.
- An archive containing one of the image's plugins, or a plugin already
  provided by another archive, is refused.

**Plugins are code.** They run with MantisBT's full access to its database and
files. Install only plugins you trust, and pin them by checksum.

### Several replicas

Each container rewrites the image's and the downloaded plugins on start. Give
every replica its own plugins volume, so that a pod starting does not change
files under one that is serving: an `emptyDir` is enough. Deliver every plugin
through `MANTIS_PLUGINS`, because folders copied into an `emptyDir` disappear
with the pod. Keep the list identical on all replicas.

## HTTPS and reverse proxies

### Behind a reverse proxy (recommended)

Terminate TLS on the proxy (HAProxy, nginx, Traefik, an OpenShift route...) and
send plain HTTP to port 8080:

```sh
-e HTTPD_TRUSTED_PROXIES=10.0.0.0/8 \
-e HTTPD_ENABLE_HTTPS=false \
-e HTTPD_SERVER_NAME=bugs.example.com \
-e MANTIS_PATH=https://bugs.example.com/
```

- **`HTTPD_TRUSTED_PROXIES`.** The access log and MantisBT see the real client
  address instead of the proxy's. Only headers coming from the listed addresses
  are trusted.
- **`X-Forwarded-Proto: https`.** Have the proxy send this header. MantisBT then
  marks its cookies `Secure` and builds `https://` links.
- **HSTS.** Set it on the proxy. This image deliberately does not send it.

### TLS in the container

When `HTTPD_ENABLE_HTTPS=true` (the default) and you supply no certificate, the
container generates a self-signed certificate for `HTTPD_SERVER_NAME` on its
first start. It is unique to that container, and is regenerated if the
container is recreated. To use your own certificate:

```sh
-v ./tls:/etc/mantis-tls:ro,Z \
-e HTTPD_TLS_CERT_FILE=/etc/mantis-tls/fullchain.pem \
-e HTTPD_TLS_KEY_FILE=/etc/mantis-tls/privkey.pem
```

The key must be readable by uid 48. Protocols and ciphers follow the system
crypto policy of the base image.

## Secrets

These variables can be supplied as a file instead of a value, by appending
`_FILE` to the name:

`MANTIS_DB_HOST`, `MANTIS_DB_USER`, `MANTIS_DB_PASSWORD`,
`MANTIS_CRYPTO_MASTER_SALT`, `MANTIS_SMTP_USERNAME`, `MANTIS_SMTP_PASSWORD`,
`MANTIS_LDAP_BIND_DN`, `MANTIS_LDAP_BIND_PASSWORD`, `MANTIS_OIDC_CLIENT_SECRET`,
`MANTIS_OIDC_CRYPTO_PASSPHRASE`, `MANTIS_PLUGINS`

```sh
printf '%s' 'change-me' | podman secret create mantis-db-password -
podman run ... --secret mantis-db-password \
  -e MANTIS_DB_PASSWORD_FILE=/run/secrets/mantis-db-password ...
```

In Kubernetes or OpenShift, mount the Secret as a file and point the `_FILE`
variable at it. Setting both `VAR` and `VAR_FILE` is an error.

The generated `config_inc.php` contains these values. It is written with mode
`0640`, and it is only as safe as the volume it is stored on. The OpenID Connect
secrets are never written there. They go only to
`/etc/httpd/conf.d/zz-oidc.conf` inside the container, mode `0600`.

## Upgrading MantisBT

1. Back up the database and both volumes.
2. Start the new image tag with the same volumes and
   `MANTIS_ADMINISTRATION_ENABLED=true`.
3. Open `/admin/install.php` and follow the upgrade steps, or run it from
   the command line:
   ```sh
   podman exec mantis-app php /var/www/html/mantis/admin/upgrade_unattended.php
   ```
4. Recreate the container without `MANTIS_ADMINISTRATION_ENABLED`.

## Operations

| Task | Command |
|---|---|
| Maintenance page on | `podman exec mantis-app setoffline` |
| Maintenance page off | `podman exec mantis-app setonline` |
| Health | `podman healthcheck run mantis-app`. Checks Apache *and* PHP-FPM, not the database. See [health checks](#health-checks-kubernetes-and-openshift). |
| Apache status | `podman exec mantis-app curl -s localhost:8080/server-status?auto` |
| PHP-FPM status | `podman exec mantis-app curl -s localhost:8080/php-status` |
| Effective PHP settings | `podman exec mantis-app cat /etc/php.d/zz-runtime.ini` |
| Effective FPM settings | `podman exec mantis-app cat /etc/php-fpm.d/zz-runtime.conf` |
| Effective Apache settings | `podman exec mantis-app cat /etc/httpd/conf.d/zz-runtime.conf` |
| Effective OpenID Connect settings (MantisBT side) | `podman exec mantis-app cat /etc/mantis/runtime_inc.php`. The Apache side, `zz-oidc.conf`, holds the client secret. |
| Email queue (when `$g_email_send_using_cronjob = ON`) | `podman exec mantis-app php /var/www/html/mantis/scripts/send_emails.php`, run from a host timer |

Logs go to stdout and stderr: `podman logs mantis-app`.

**Healthcheck.** It is stored in the image in Docker format. With podman, the
health status is shown by `podman ps` and `podman healthcheck run`.

## Health checks, Kubernetes and OpenShift

### Health endpoints

| URL | Checks | Use it for |
|---|---|---|
| `/healthz.php` | Apache is serving and PHP-FPM is executing PHP. Does **not** touch MantisBT or the database. Not written to the access log. | **Liveness** and **startup** probes, and the image's `HEALTHCHECK`. |
| `/login_page.php` (under `MANTIS_CONTEXT_PATH` if set) | MantisBT can serve users, which includes reaching the database. | **Readiness** probe. |

Keep the two apart. If liveness depended on the database, a database outage
would get every MantisBT pod restarted in a loop, which fixes nothing and
delays recovery. With the split, a database outage only takes the pods out of
the Service until the database is back.

Both URLs are on port 8080 and need no configuration. The status pages
(`/server-status`, `/php-status`) are deliberately **not** suitable as probes:
they only answer to localhost, and probes come from the node.

### Probes

```yaml
containers:
  - name: mantis
    image: quay.io/ricardoalonsos/mantis:2.28.4
    ports:
      - containerPort: 8080
    startupProbe:
      httpGet: { path: /healthz.php, port: 8080 }
      periodSeconds: 2
      failureThreshold: 30        # up to 60 s for the first start
    livenessProbe:
      httpGet: { path: /healthz.php, port: 8080 }
      periodSeconds: 10
      timeoutSeconds: 5
      failureThreshold: 3
    readinessProbe:
      httpGet: { path: /login_page.php, port: 8080 }
      periodSeconds: 10
      timeoutSeconds: 5
      failureThreshold: 3
```

The readiness probe fails until the database schema exists. During the first
installation the pod is therefore not ready, and the Route will not send it any
traffic. For the installation, either reach the pod directly
(`oc port-forward deploy/mantis 8080:8080`, then open
`http://localhost:8080/admin/install.php`), or add the readiness probe
after installing.

### OpenShift and OKD

- **Arbitrary user IDs.** The image runs under the `restricted-v2` SCC as is.
  OpenShift assigns a random UID with group 0, and every path the container
  writes to is group-writable by group 0. No `anyuid` is needed.
- **Routes.** Use an `edge` Route (TLS terminated at the router) to port 8080,
  and set:
  ```yaml
  - { name: HTTPD_ENABLE_HTTPS,    value: "false" }
  - { name: HTTPD_TRUSTED_PROXIES, value: "10.128.0.0/14" }   # your cluster network
  - { name: MANTIS_PATH,           value: "https://bugs.apps.example.com/" }
  ```
  Use `oc get network.config cluster -o jsonpath='{.spec.clusterNetwork}'` for
  the cluster network. If your routers run on the host network, use the node
  network instead. The router sends `X-Forwarded-Proto`, so MantisBT produces
  `https://` links and secure cookies.
- **Volumes.** Use a PersistentVolumeClaim for `/mantis/config` and one for
  `/mantis/attachments`. For `/mantis/plugins`, see
  [several replicas](#several-replicas). The `fsGroup` that OpenShift sets makes them writable.
  With more than one replica, the attachments volume must be `ReadWriteMany`,
  or set `MANTIS_FILE_UPLOAD_METHOD=DATABASE` before the first installation.
- **More than one replica.** MantisBT keeps its anti-CSRF form tokens in the
  PHP session, which is stored inside each pod. Keep the router's default
  cookie-based session affinity enabled (do not set
  `haproxy.router.openshift.io/disable_cookies`). Otherwise forms fail with
  "invalid form security token" when consecutive requests reach different pods.
- **Secrets.** Mount a Secret as files and use the `_FILE` variables (see
  [Secrets](#secrets)), e.g. `MANTIS_DB_PASSWORD_FILE=/var/run/secrets/mantis/db-password`.
- **Metrics.** To scrape `/server-status` or `/php-status`, run the exporter
  (`apache_exporter`, `php-fpm_exporter`) as a sidecar in the same pod: it
  reaches them over `localhost` and needs no change. To scrape the pod
  directly instead, set `HTTPD_STATUS_ALLOW` to the address range of your
  monitoring pods.

## Troubleshooting

**The container exits immediately.** Run `podman logs <container>`. Startup
errors start with `[entrypoint] ERROR:` and name the variable or file that is
wrong.

**"No config_inc.php, no MANTIS_DB_HOST, and the admin pages are disabled".**
This is a fresh volume with nothing configured. Set the `MANTIS_DB_*` variables,
or set `MANTIS_ADMINISTRATION_ENABLED=true` and use the web installer.

**I changed `MANTIS_DB_PASSWORD` (or another `MANTIS_*` setting) and nothing
happened.** `config_inc.php` is generated only once. Edit it on the volume, or
delete it so it is generated again.

**Uploads fail or are smaller than expected.** Raise `PHP_UPLOAD_MAX_FILESIZE`.
`PHP_POST_MAX_SIZE` follows it automatically. Check the proxy's body size limit
too (for example `client_max_body_size` in nginx).

**"is not writable by uid 48".** A bind-mounted directory is owned by your user.
Run `podman unshare chown -R 48:0 <dir>`.

**Edits to `config_inc.php` are ignored.** You set
`PHP_OPCACHE_VALIDATE_TIMESTAMPS=Off`. Restart the container.

**A plugin I copied does not appear in Manage Plugins.** The folder name must
match the main file, `Name/Name.php`, and the file must declare
`class NamePlugin`. The startup log lists every plugin found, under
`Plugins: bundled ...; downloaded ...; your own ...`.

**"checksum mismatch" for a plugin archive.** The file at that URL is not the
one you pinned. A release asset was replaced, or the URL points at a branch.
Check the file, then update the checksum.

**Single sign-on problems.** See the troubleshooting section of
[README-authentication.md](README-authentication.md#troubleshooting). If the
identity provider is down, log in with a break-glass account at
`/login_page.php?local=1`.

## Changes from earlier images

If you ran an earlier image, check these before upgrading:

| Change | Before | Now | Action |
|---|---|---|---|
| `MANTIS_ADMINISTRATION_ENABLED` default | `true` | `false` | Set it to `true` explicitly for installs and upgrades. |
| Boolean values | `true`/`false` only, others misbehaved (`yes` hung the container) | `true/false/yes/no/on/off/1/0`, anything else is an error | — |
| `PHP_MEMORY_LIMIT` default | `1024M` | `256M` | Set it back if you relied on it. |
| `HTTPD_REQUEST_TIMEOUT` default | `300` | `60` | — |
| PHP-FPM workers | 150, fixed | `PHP_FPM_MAX_CHILDREN`, default 20 | Raise it for very busy installations. |
| `post_max_size` | equal to the upload size | 4 × upload size, or `PHP_POST_MAX_SIZE` | — |
| `/server-status`, `/php-status` | open to everyone | localhost only | Use `HTTPD_STATUS_ALLOW` for monitoring from outside. |
| TLS certificate | the same self-signed key in every copy of the image | generated per container, or your own | — |
| Access log client address | always the proxy | the real client, with `HTTPD_TRUSTED_PROXIES` | — |
| MantisBT URL | `/mantis/`, with `/` redirecting there | `/`, or `MANTIS_CONTEXT_PATH` | Set `MANTIS_CONTEXT_PATH=/mantis` to keep existing links, bookmarks and `MANTIS_PATH` working. |
| `HEALTHCHECK` URL | `/mantis/login_page.php` (failed when the database was down) | `/healthz.php` (no database) | Use `/healthz.php` for liveness and `/login_page.php` (under the context path) for readiness. |
| PHP errors | discarded (PHP-FPM dropped its workers' stderr) | in the container log | — |
| Generated `config_inc.php` | — | also loads `/etc/mantis/runtime_inc.php` at the end | Needed only for OpenID Connect. Older files are left alone; the container says what to add if you turn OIDC on. |
| `plugins/` | inside the image | the `/mantis/plugins` volume, refilled with the image's plugins on start | Plugins you had copied into the old container must be copied into the volume, or listed in `MANTIS_PLUGINS`. |
| Email without `MANTIS_SMTP_HOST` | not applicable | notifications off, in a generated `config_inc.php` only | Existing `config_inc.php` files are not touched. |
