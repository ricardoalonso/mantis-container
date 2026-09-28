#!/bin/bash
# Build-time installation of MantisBT.
#
# Fails loudly. Every step here has to succeed for the image to be usable, and
# an image that builds "successfully" without MantisBT in it is far more
# expensive to diagnose than a build that stops.
set -euo pipefail

PERMISSION_CHANGE="/mantis /etc/httpd /var/log/httpd /run/httpd /var/www/html /run/php-fpm /etc/php.ini /etc/php*"
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
sed -i 's/^[[:blank:]]*CustomLog.*/CustomLog \/dev\/stdout combined /' /etc/httpd/conf/httpd.conf
sed -i 's/Listen.*/Listen 8080/' /etc/httpd/conf/httpd.conf

# /etc/httpd/conf.d/ssl.conf
# TODO Allow custom certificate
make-dummy-cert /etc/pki/tls/certs/localhost.crt
chown apache:0 /etc/pki/tls/certs/localhost.crt
chmod g=u /etc/pki/tls/certs/localhost.crt

# /etc/httpd/conf.d/remoteip.conf
#echo "RemoteIPProxyProtocol On" >> /etc/httpd/conf.d/remoteip.conf

sed -i '/^SSLCertificateKeyFile/s/^/#/' /etc/httpd/conf.d/ssl.conf
sed -i 's/^Listen.*/Listen 0.0.0.0:8443 https/' /etc/httpd/conf.d/ssl.conf
sed -i 's/_default_:443/_default_:8443/' /etc/httpd/conf.d/ssl.conf
sed -i 's/^[[:blank:]]*CustomLog.*/CustomLog \/dev\/stdout \\/' /etc/httpd/conf.d/ssl.conf
sed -i 's/^[[:blank:]]*TransferLog.*/TransferLog \/dev\/stdout/' /etc/httpd/conf.d/ssl.conf
sed -i 's/^[[:blank:]]*ErrorLog.*/ErrorLog \/dev\/stderr/' /etc/httpd/conf.d/ssl.conf

say "Configuring PHP"
# /etc/php.ini
sed -i 's/.*mysqli.allow_persistent =.*/mysqli.allow_persistent = On/' /etc/php.ini

# /etc/php-fpm.conf
sed -i 's/^daemonize.*/daemonize = no/' /etc/php-fpm.conf
sed -i 's/^error_log.*/error_log = \/dev\/stderr/' /etc/php-fpm.conf

# /etc/php-fpm.d/www.conf
sed -i 's/^slowlog.*/slowlog = \/dev\/stderr/' /etc/php-fpm.d/www.conf
sed -i 's/^php_admin_value\[error_log\].*/php_admin_value\[error_log\] = \/dev\/stderr/' /etc/php-fpm.d/www.conf
sed -i 's/.*pm.status_path =.*/pm.status_path = \/php-status/' /etc/php-fpm.d/www.conf
# set equals to default apache max_clients/max_connections
sed -i 's/.*pm.max_children =.*/pm.max_children = 150/' /etc/php-fpm.d/www.conf
sed -i 's/.*pm.max_requests =.*/pm.max_requests = 100/' /etc/php-fpm.d/www.conf

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
say "Tidying up"
# Move Mantis folders away from the public accessible folder
# Only config at the moment due to https://www.mantisbt.org/bugs/view.php?id=21584
mkdir -p /mantis/attachments
mv mantis/config /mantis

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
test -d /mantis/config \
	|| { echo "error: config directory was not relocated" >&2; exit 1; }

say "MantisBT ${MANTIS_VERSION} installed"
