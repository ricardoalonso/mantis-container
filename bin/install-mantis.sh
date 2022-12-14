#!/bin/bash

PERMISSION_CHANGE="/mantis /etc/httpd /var/log/httpd /run/httpd /var/www/html /run/php-fpm /etc/php.ini /etc/php*"
PATCHES_DIR="patches/$MANTIS_VERSION"

# Download and install Mantis BT
curl -so mantis.tgz https://altushost-swe.dl.sourceforge.net/project/mantisbt/mantis-stable/$MANTIS_VERSION/mantisbt-$MANTIS_VERSION.tar.gz
tar xf mantis.tgz
mv mantisbt-$MANTIS_VERSION/* .
rm -rf mantis.tgz mantisbt-$MANTIS_VERSION

### Config files updates 
# /etc/httpd/conf/httpd.conf
sed -i 's/^[[:blank:]]*ErrorLog.*/ErrorLog \/dev\/stderr/' /etc/httpd/conf/httpd.conf
sed -i 's/^[[:blank:]]*CustomLog.*/CustomLog \/dev\/stdout combined /' /etc/httpd/conf/httpd.conf 
sed -i 's/Listen.*/Listen 8080/' /etc/httpd/conf/httpd.conf 

# /etc/httpd/conf.d/timeout.conf
echo "Timeout $REQUEST_TIMEOUT" >> /etc/httpd/conf.d/timeout.conf

# /etc/httpd/conf.d/ssl.conf
# TODO Allow custom certificate
make-dummy-cert /etc/pki/tls/certs/localhost.crt 
chown apache.0 /etc/pki/tls/certs/localhost.crt
chmod g=u /etc/pki/tls/certs/localhost.crt

sed -i '/^SSLCertificateKeyFile/s/^/#/' /etc/httpd/conf.d/ssl.conf 
sed -i 's/^Listen.*/Listen 0.0.0.0:8443 https/' /etc/httpd/conf.d/ssl.conf 
sed -i 's/_default_:443/_default_:8443/' /etc/httpd/conf.d/ssl.conf 
sed -i 's/^[[:blank:]]*CustomLog.*/CustomLog \/dev\/stdout \\/' /etc/httpd/conf.d/ssl.conf 
sed -i 's/^[[:blank:]]*TransferLog.*/TransferLog \/dev\/stdout/' /etc/httpd/conf.d/ssl.conf 
sed -i 's/^[[:blank:]]*ErrorLog.*/ErrorLog \/dev\/stderr/' /etc/httpd/conf.d/ssl.conf 

# /etc/php-fpm.conf
sed -i 's/^daemonize.*/daemonize = no/' /etc/php-fpm.conf

# /etc/php-fpm.d/www.conf
sed -i 's/^slowlog.*/slowlog = \/dev\/stderr/' /etc/php-fpm.d/www.conf
sed -i 's/^php_admin_value\[error_log\].*/php_admin_value\[error_log\] = \/dev\/stderr/' /etc/php-fpm.d/www.conf
sed -i 's/^error_log.*/error_log = \/dev\/stderr/' /etc/php-fpm.conf

# Apply patches to mantis code
if [ -d "$PATCHES_DIR" ]
then
    for p in $(ls $PATCHES_DIR/*.patch)
    do
        echo "Applying patch $p"
        patch -p1 < $p
    done
    rm -rf patches
fi

# Move Mantis folders away from the public accessible folder
# Only config at the moment due to https://www.mantisbt.org/bugs/view.php?id=21584
mkdir -p /mantis/attachments
mv config /mantis

# Remove files and folders not necessary
rm -rf doc

# Fix permissions
mkdir /run/php-fpm

chown -R apache.0 $PERMISSION_CHANGE
chmod -R g=u $PERMISSION_CHANGE
