#!/bin/bash

PERMISSION_CHANGE="/mantis /etc/httpd /var/log/httpd /run/httpd /var/www/html /run/php-fpm /etc/php.ini /etc/php*"
PATCHES_DIR="patches/$MANTIS_VERSION"

# Download and install Mantis BT
curl -so mantis.tgz https://altushost-swe.dl.sourceforge.net/project/mantisbt/mantis-stable/$MANTIS_VERSION/mantisbt-$MANTIS_VERSION.tar.gz
tar xf mantis.tgz
mv mantisbt-$MANTIS_VERSION mantis
rm -rf mantis.tgz mantisbt-$MANTIS_VERSION

### Config files updates 
# /etc/httpd/conf/httpd.conf
sed -i 's/^[[:blank:]]*ErrorLog.*/ErrorLog \/dev\/stderr/' /etc/httpd/conf/httpd.conf
sed -i 's/^[[:blank:]]*CustomLog.*/CustomLog \/dev\/stdout combined /' /etc/httpd/conf/httpd.conf 
sed -i 's/Listen.*/Listen 8080/' /etc/httpd/conf/httpd.conf 

# /etc/httpd/conf.d/ssl.conf
# TODO Allow custom certificate
make-dummy-cert /etc/pki/tls/certs/localhost.crt 
chown apache.0 /etc/pki/tls/certs/localhost.crt
chmod g=u /etc/pki/tls/certs/localhost.crt

# /etc/httpd/conf.d/remoteip.conf
#echo "RemoteIPProxyProtocol On" >> /etc/httpd/conf.d/remoteip.conf

sed -i '/^SSLCertificateKeyFile/s/^/#/' /etc/httpd/conf.d/ssl.conf 
sed -i 's/^Listen.*/Listen 0.0.0.0:8443 https/' /etc/httpd/conf.d/ssl.conf 
sed -i 's/_default_:443/_default_:8443/' /etc/httpd/conf.d/ssl.conf 
sed -i 's/^[[:blank:]]*CustomLog.*/CustomLog \/dev\/stdout \\/' /etc/httpd/conf.d/ssl.conf 
sed -i 's/^[[:blank:]]*TransferLog.*/TransferLog \/dev\/stdout/' /etc/httpd/conf.d/ssl.conf 
sed -i 's/^[[:blank:]]*ErrorLog.*/ErrorLog \/dev\/stderr/' /etc/httpd/conf.d/ssl.conf 

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

# Apply patches to mantis code
if [ -d "$PATCHES_DIR" ]
then
    for p in $(ls $PATCHES_DIR/*.patch)
    do
        echo "Applying patch $p"
        patch -d mantis/ -p1 < $p
    done
    rm -rf patches
fi

# Move Mantis folders away from the public accessible folder
# Only config at the moment due to https://www.mantisbt.org/bugs/view.php?id=21584
mkdir -p /mantis/attachments
mv mantis/config /mantis

# Remove files and folders not necessary
rm -rf doc

# Fix permissions
mkdir /run/php-fpm

chown -R apache.0 $PERMISSION_CHANGE
chmod -R g=u $PERMISSION_CHANGE
