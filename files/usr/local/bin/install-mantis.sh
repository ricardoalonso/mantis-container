#!/bin/bash
# Build-time installation of MantisBT.
#
# Fails loudly. Every step here has to succeed for the image to be usable, and
# an image that builds "successfully" without MantisBT in it is far more
# expensive to diagnose than a build that stops.
set -euo pipefail

PERMISSION_CHANGE="/mantis /etc/mantis /etc/httpd /var/log/httpd /run/httpd /var/www/html /run/php-fpm /etc/php.ini /etc/php*"
PATCHES_DIR="/build/patches"
CHECKSUMS="/build/checksums.sha256"
TARBALL="mantisbt-${MANTIS_VERSION}.tar.gz"
URL="https://master.dl.sourceforge.net/project/mantisbt/mantis-stable/${MANTIS_VERSION}/${TARBALL}?viasf=1"

say() { printf '\n==> %s\n' "$*"; }

# -----------------------------------------------------------------------------
say "Downloading MantisBT ${MANTIS_VERSION}"
# -f so an HTTP error is an error rather than an error page saved as the
# tarball, and -L because SourceForge redirects to a mirror. Without either,
# the build happily writes a redirect page to mantis.tgz and carries on.
curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 -o "$TARBALL" "$URL"

say "Verifying checksum"
if ! grep -q "  ${TARBALL}\$" "$CHECKSUMS"; then
	echo "error: no checksum recorded for ${TARBALL} in checksums.sha256." >&2
	echo "       Add one before building this version." >&2
	exit 1
fi
grep "  ${TARBALL}\$" "$CHECKSUMS" | sha256sum --check --strict -

say "Extracting"
tar xf "$TARBALL"
mv "mantisbt-${MANTIS_VERSION}" mantis
rm -f "$TARBALL"

# -----------------------------------------------------------------------------
say "Configuring Apache"
# /etc/httpd/conf/httpd.conf
sed -i 's/^[[:blank:]]*ErrorLog.*/ErrorLog \/dev\/stderr/' /etc/httpd/conf/httpd.conf
# env=!dontlog: probe hits on /healthz.php are not logged (conf.d/healthz.conf).
sed -i 's/^[[:blank:]]*CustomLog.*/CustomLog \/dev\/stdout combined env=!dontlog/' /etc/httpd/conf/httpd.conf
sed -i 's/Listen.*/Listen 8080/' /etc/httpd/conf/httpd.conf
# Log the client address (%a) rather than the connection's (%h). They are the
# same until HTTPD_TRUSTED_PROXIES enables mod_remoteip; then %a is the real
# client and %h would be the proxy.
sed -i 's/^\([[:blank:]]*LogFormat "\)%h /\1%a /' /etc/httpd/conf/httpd.conf

# TLS. The distribution's ssl.conf is replaced by /etc/httpd/mantis-ssl.conf,
# which zz-runtime.conf includes only when HTTPD_ENABLE_HTTPS is true. No
# certificate is generated here: one made at build time would put the same
# private key in every copy of the published image. apply-parameters.sh makes
# one per container, or uses HTTPD_TLS_CERT_FILE / HTTPD_TLS_KEY_FILE.
rm -f /etc/httpd/conf.d/ssl.conf
mkdir -p /etc/httpd/tls
# DocumentRoot when MantisBT is served under a context path rather than at /
# (MANTIS_CONTEXT_PATH; see apply-parameters.sh). Empty on purpose, so nothing
# but the redirect to the context and /healthz.php answers outside it.
mkdir -p /var/www/empty

# OpenID Connect. apply-parameters.sh loads mod_auth_openidc and writes its
# configuration only when MANTIS_OIDC_ISSUER is set, so the package's own files
# go: with them the module would be in every server, configured or not.
rm -f /etc/httpd/conf.modules.d/10-auth_openidc.conf /etc/httpd/conf.d/auth_openidc.conf
# Where apply-parameters.sh writes the MantisBT side (runtime_inc.php).
mkdir -p /etc/mantis

say "Configuring PHP"
# /etc/php.ini
sed -i 's/.*mysqli.allow_persistent =.*/mysqli.allow_persistent = On/' /etc/php.ini

# /etc/php-fpm.conf
sed -i 's/^daemonize.*/daemonize = no/' /etc/php-fpm.conf
sed -i 's/^error_log.*/error_log = \/dev\/stderr/' /etc/php-fpm.conf

# /etc/php-fpm.d/www.conf
sed -i 's/^slowlog.*/slowlog = \/dev\/stderr/' /etc/php-fpm.d/www.conf
sed -i 's/^php_admin_value\[error_log\].*/php_admin_value\[error_log\] = \/dev\/stderr/' /etc/php-fpm.d/www.conf
# A worker's stderr is /dev/null unless FPM catches it, so without these the
# error_log above discarded every PHP error. Undecorated: the message as is,
# without FPM's "child 12 said into stderr" wrapper.
sed -i 's/^;\?catch_workers_output =.*/catch_workers_output = yes/' /etc/php-fpm.d/www.conf
grep -q '^catch_workers_output = yes' /etc/php-fpm.d/www.conf
echo 'decorate_workers_output = no' >> /etc/php-fpm.d/www.conf
sed -i 's/.*pm.status_path =.*/pm.status_path = \/php-status/' /etc/php-fpm.d/www.conf
# Pool sizing (pm.*, request_terminate_timeout) is set at runtime from the
# PHP_FPM_* variables, in /etc/php-fpm.d/zz-runtime.conf.
# Defence in depth for php2shell (CVE-2026-109619), per Red Hat RHSB-2026-013.
# MantisBT does not use upload progress. php_admin_flag so that .user.ini and
# ini_set() cannot turn it back on. Patching PHP is the actual fix -- see the
# version gate in the Containerfile.
echo 'php_admin_flag[session.upload_progress.enabled] = off' >> /etc/php-fpm.d/www.conf

# -----------------------------------------------------------------------------
# Apply patches to the Mantis code. A patch that does not apply is a build
# failure: the patched behaviour is the whole point of the image.
if compgen -G "$PATCHES_DIR/*.patch" > /dev/null; then
	for p in "$PATCHES_DIR"/*.patch; do
		say "Applying patch $(basename "$p")"
		patch -d mantis/ -p1 --batch --forward --fuzz=0 < "$p"
	done
else
	say "No patches for ${MANTIS_VERSION}"
fi

# -----------------------------------------------------------------------------
say "Installing the plugins"
# MantisBT's plugins/ becomes a symlink to the /mantis/plugins volume, so
# plugins can be added without rebuilding the image. The image's own plugins
# (MantisBT's, and OidcAuth, shipped in files/) are kept aside and copied into
# the volume on every start by install-plugins.sh.
mv mantis/plugins /usr/local/lib/mantis/bundled-plugins
mv /usr/local/lib/mantis/plugins/OidcAuth /usr/local/lib/mantis/bundled-plugins/
rmdir /usr/local/lib/mantis/plugins
rm -f /usr/local/lib/mantis/bundled-plugins/Web.config
mkdir -p /mantis/plugins
ln -s /mantis/plugins mantis/plugins

# -----------------------------------------------------------------------------
say "Tidying up"
# Move Mantis folders away from the public accessible folder
# Only config at the moment due to https://www.mantisbt.org/bugs/view.php?id=21584
mkdir -p /mantis/attachments
mv mantis/config /mantis
# Empty mount points for site customisation; see README-usage.md.
mkdir -p /mantis/conf.d/php /mantis/conf.d/php-fpm /mantis/conf.d/httpd /mantis/entrypoint.d

# Documentation is not served, and is a large part of the tree. Note these are
# under mantis/, not the working directory -- the previous `rm -rf doc` matched
# nothing and shipped both directories.
rm -rf mantis/doc mantis/docbook

say "Fixing permissions"
mkdir -p /run/php-fpm
# shellcheck disable=SC2086  # deliberate word splitting; the list contains a glob
chown -R apache:0 $PERMISSION_CHANGE
# shellcheck disable=SC2086
chmod -R g=u $PERMISSION_CHANGE

# -----------------------------------------------------------------------------
# Belt and braces on top of `set -e`: this is the one failure that must never
# reach a registry.
say "Verifying installation"
test -f /var/www/html/mantis/index.php \
	|| { echo "error: MantisBT is not present after install" >&2; exit 1; }
test -f /usr/local/lib/mantis/bundled-plugins/OidcAuth/OidcAuth.php \
	|| { echo "error: the OidcAuth plugin is not installed" >&2; exit 1; }
test -f /usr/local/lib/mantis/bundled-plugins/MantisCoreFormatting/MantisCoreFormatting.php \
	|| { echo "error: MantisBT's own plugins were not set aside" >&2; exit 1; }
test -L /var/www/html/mantis/plugins \
	|| { echo "error: mantis/plugins is not a symlink to /mantis/plugins" >&2; exit 1; }
test -d /mantis/config \
	|| { echo "error: config directory was not relocated" >&2; exit 1; }

say "MantisBT ${MANTIS_VERSION} installed"
