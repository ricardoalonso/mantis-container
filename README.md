# mantis-container

MantisBT on Apache 2.4 + PHP-FPM, on Rocky Linux 9, with local patches applied
at build time.

## Build

```sh
./build.sh              # the version in the Containerfile
./build.sh 2.27.1       # a specific version
./smoke-test.sh         # start it and check it actually works
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

| Variable | Default |
|---|---|
| `MANTIS_CONFIG_FOLDER` | `/mantis/config/` |
| `MANTIS_ADMINISTRATION_ENABLED` | `true` |
| `PHP_UPLOAD_MAX_FILESIZE` | `4M` |
| `PHP_MEMORY_LIMIT` | `1024M` |
| `PHP_DISPLAY_ERRORS` | `Off` |
| `PHP_MAX_EXECUTION_TIME` | `30` |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `On` |
| `HTTPD_REQUEST_TIMEOUT` | `300` |

Setting `PHP_OPCACHE_VALIDATE_TIMESTAMPS=Off` removes a stat per included file
per request. The application code in the image never changes, so this is safe
— but `config_inc.php` lives on a volume, and with it Off an edit there needs a
container restart to take effect.

Ports 8080 (http) and 8443 (https, self-signed dummy certificate — put a real
proxy in front). Volumes at `/mantis/config` and `/mantis/attachments`.

## Apache configuration

Three drop-ins under `files/etc/httpd/conf.d/`:

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

PHP tuning is in `files/etc/php.d/99-mantis.ini`, mostly opcache sizing for a
~1100 file codebase. The MPM is already `event`, which is correct with PHP-FPM.

The entrypoint supervises php-fpm and httpd together: if either exits on its
own the container exits non-zero, so a restart policy recovers it. A `stop`
exits 0. `HEALTHCHECK` requests a PHP page, so it fails if php-fpm is dead even
while Apache still answers.
