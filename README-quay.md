# MantisBT container image

[MantisBT](https://mantisbt.org/) on Apache 2.4 and PHP-FPM, on Rocky Linux 9.
It includes local patches for attachment storage and LDAP user creation, and
optional single sign-on through OpenID Connect.

Tags follow the MantisBT version, e.g. `quay.io/ricardoalonsos/mantis:2.28.4`.

**Full documentation:**
[usage guide](https://github.com/ricardoalonso/mantis-container/blob/main/README-usage.md)
and
[single sign-on](https://github.com/ricardoalonso/mantis-container/blob/main/README-authentication.md).
Both are also inside the image, in `/usr/share/doc/mantis-container/`.

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

Then open `http://localhost:8080/admin/install.php` to create the database
schema, and log in as `administrator` / `root`. **Change that password
immediately**, and recreate the container without
`MANTIS_ADMINISTRATION_ENABLED` to turn the admin pages off again.

## Ports, volumes and user

- `8080/tcp`: HTTP.
- `8443/tcp`: HTTPS, self-signed by default.
- `/mantis/config`: **volume** for `config_inc.php`.
- `/mantis/attachments`: **volume** for uploaded files.
- `/mantis/plugins`: **volume** for MantisBT's plugins.
- `/mantis/conf.d/{php,php-fpm,httpd}`: optional configuration drop-ins.
- `/mantis/entrypoint.d`: optional startup hooks.

The container runs as `apache` (uid 48, gid 0), and runs unchanged under
OpenShift's `restricted-v2` SCC. Bind-mounted directories must be writable by
uid 48: `podman unshare chown -R 48:0 <dir>`.

## Configuration

Everything is configured through environment variables, and every value is
checked at startup. The main groups:

- `MANTIS_DB_*`, `MANTIS_SMTP_*`, `MANTIS_LDAP_*`: used once, to generate
  `config_inc.php` on first start. After that, the file on the volume is the
  source of truth.
- `MANTIS_OIDC_*`: single sign-on through Keycloak, Entra ID, Okta and others.
- `MANTIS_PLUGINS`: plugin archives to download and install, pinned by SHA-256.
- `PHP_*`, `PHP_FPM_*`, `HTTPD_*`: PHP, PHP-FPM and Apache tuning. Any other
  setting can be passed as `PHP_INI_<key>` or `PHP_FPM_POOL_<key>`.
- `MANTIS_CONTEXT_PATH`: serve MantisBT under a sub-path, e.g. `/mantis`.

Secrets can be passed as files by appending `_FILE` to the variable name,
e.g. `MANTIS_DB_PASSWORD_FILE=/run/secrets/mantis-db-password`.

See the
[configuration reference](https://github.com/ricardoalonso/mantis-container/blob/main/README-usage.md#configuration-reference)
for every variable and its default.

## Health checks

- `/healthz.php`: Apache and PHP-FPM are working. It does not touch the
  database. Use it for liveness and startup probes.
- `/login_page.php`: MantisBT can reach its database. Use it for readiness.

## Upgrading from an earlier image

Some defaults have changed. Notably, MantisBT is now served at `/` instead of
`/mantis/`, and the admin pages are off by default. Read
[changes from earlier images](https://github.com/ricardoalonso/mantis-container/blob/main/README-usage.md#changes-from-earlier-images)
before upgrading.
