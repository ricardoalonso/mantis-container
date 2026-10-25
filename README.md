# mantis-container

MantisBT on Apache 2.4 + PHP-FPM, on Rocky Linux 9, with local patches applied
at build time.

## Build

```sh
./build.sh              # the version in the Containerfile
./build.sh 2.27.1       # a specific version
./smoke-test.sh         # start it and check it actually works
./oidc-test.sh          # OpenID Connect login end to end, against a real IdP
./push.sh               # publish; add --latest to move the latest tag
```

`build.sh` refuses to build a version that has no `patches/<version>/` directory
or no entry in `checksums.sha256`, so a typo fails immediately rather than
producing an image without the patched behaviour.

## Adding a MantisBT version

1. Download the tarball, satisfy yourself it is genuine, and add its SHA256 to
   `checksums.sha256`.
2. Generate the patch for that release (see below) into `patches/<version>/`.
3. Change `ARG MANTIS_VERSION` in the `Containerfile`.
4. `./build.sh && ./smoke-test.sh`

## Patches

`patches/<version>/*.patch` is applied with `patch -p1` against the extracted
release. A patch that fails to apply fails the build.

They are generated from a branch in the MantisBT checkout that cherry-picks the
changes onto the matching release tag:

```sh
cd ~/git/mantisbt
git diff release-2.28.4..pdcase-2.28.4 -- . ':(exclude)tests/' \
  > ~/git/mantis-container/patches/2.28.4/0001-attachments_and_ldap.patch
```

Tests are excluded deliberately: they never run in the container.

The current patch covers attachment storage (honouring the `folder` column,
moving attachments correctly between projects, and an optional subdirectory
layout) plus hiding the unusable local password field under LDAP.

### Required configuration

The subdirectory layout is off by default. To use it, `config_inc.php` needs:

```php
$g_file_upload_subdirectory_depth = 1;
$g_file_upload_subdirectory_width = 2;
```

Without it, existing attachments still resolve, but new uploads land flat.
`admin/reorganize_attachments.php` migrates files already on disk, in either
direction.

## Reproducibility

- The base image is pinned by digest in the `Containerfile`. Bump it
  deliberately:
  ```sh
  podman pull quay.io/rockylinux/rockylinux:9
  podman inspect quay.io/rockylinux/rockylinux:9 --format '{{index .RepoDigests 0}}'
  ```
- The MantisBT tarball is checksum-verified against `checksums.sha256`.
- The version lives only in `ARG MANTIS_VERSION`; `build.sh` and `push.sh` read
  it back, so the tag cannot drift from the contents.
- `build.sh` passes `--format docker`, because podman's default OCI format
  silently discards `HEALTHCHECK`.

## Runtime

Everything about running the image -- every variable and its default, the
drop-in directories, hooks, TLS, proxies and secrets -- is in
[README-usage.md](README-usage.md). That file is copied into the image at
`/usr/share/doc/mantis-container/README-usage.md`; paste it into the quay.io
repository description when publishing a release.

How it fits together:

- `files/usr/local/lib/mantis/common.sh` holds the defaults and the validation
  helpers. It is the only place defaults live: the `Containerfile` does not
  repeat them as `ENV`. Change a default there **and** in README-usage.md.
- `apply-parameters.sh` validates every value, then rewrites
  `/etc/php.d/zz-runtime.ini`, `/etc/php-fpm.d/zz-runtime.conf` and
  `/etc/httpd/conf.d/zz-runtime.conf` from scratch on each start, and copies the
  `/mantis/conf.d` drop-ins after them. Distribution files are no longer edited
  with `sed` at runtime.
- `mantis-config.sh` writes `config_inc.php` from `MANTIS_*` variables when the
  volume has none.
- OpenID Connect (`MANTIS_OIDC_*`) is configured by `apply-parameters.sh` on
  every start, in two halves: `/etc/httpd/conf.d/zz-oidc.conf` for
  mod_auth_openidc, and `/etc/mantis/runtime_inc.php`, which `config_inc.php`
  loads last, for the `OidcAuth` plugin. The plugin's source is in
  `files/usr/local/lib/mantis/plugins/OidcAuth/`. The design and its reasons are in
  [README-authentication.md](README-authentication.md). It is shipped in the
  image too.
- `install-plugins.sh` fills the `/mantis/plugins` volume on every start.
  MantisBT's `plugins/` is a symlink to it. At build time `install-mantis.sh`
  sets the image's own plugins aside in `/usr/local/lib/mantis/bundled-plugins/`
  (MantisBT's plus `OidcAuth`), and the script copies them in, then installs
  the `MANTIS_PLUGINS` downloads. Folders it did not put there are left alone.
- `run.sh` calls them, toggles the admin pages, runs `/mantis/entrypoint.d`
  hooks, checks the configuration (`php`, `php-fpm -t`, `httpd -t`) and then
  supervises the two processes.

Adding a variable: give it a default in `common.sh`, validate and write it in
`apply-parameters.sh` (or `mantis-config.sh`), document it in README-usage.md,
and add a check to `smoke-test.sh`.

## Apache configuration

Three static drop-ins under `files/etc/httpd/conf.d/`, plus `zz-runtime.conf`
generated at startup (ServerName, timeouts, the URL MantisBT is served at
from `MANTIS_CONTEXT_PATH`, mod_remoteip, the status pages,
and the include of `files/etc/httpd/mantis-ssl.conf` when HTTPS is on):

- `mantis.conf` sets `AllowOverride All` on the MantisBT tree. This matters:
  MantisBT ships thirteen `.htaccess` files that deny access to `core/`,
  `library/`, `vendor/`, `lang/`, `scripts/` and `plugins/`, and carry the
  rewrite rules the REST API needs. Apache's default `AllowOverride None`
  ignored all of them, leaving the source tree browsable. `Options -Indexes`
  is set as well, so no directory index is ever generated.
- `zz-mantis-security.conf` — `ServerTokens Prod`, `TraceEnable Off`, drops
  `X-Powered-By`, and adds `X-Content-Type-Options` / `Referrer-Policy` to the
  responses MantisBT does not generate itself. HSTS is deliberately left to the
  TLS terminator in front.
- `zz-mantis-performance.conf` — gzip for text types (~65-70% on MantisBT's CSS
  and JS), far-future expiry for static assets (MantisBT already cache-busts
  them with `?cache_key=`), and KeepAlive.

Static PHP tuning is in `files/etc/php.d/99-mantis.ini`, mostly opcache sizing
for a ~1100 file codebase. The MPM is already `event`, which is correct with PHP-FPM.

The entrypoint supervises php-fpm and httpd together: if either exits on its
own the container exits non-zero, so a restart policy recovers it. A `stop`
exits 0. `HEALTHCHECK` requests `/healthz.php`, a PHP page that does not touch
the database: it fails if php-fpm is dead even while Apache still answers, but
not when only the database is down. Readiness belongs on
`/login_page.php` (under `MANTIS_CONTEXT_PATH`); README-usage.md has probe examples for Kubernetes and
OpenShift.
