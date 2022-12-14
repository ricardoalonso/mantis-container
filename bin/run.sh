#!/bin/bash

# Variables
echo "SetEnv MANTIS_CONFIG_FOLDER ${MANTIS_CONFIG_FOLDER:-/mantis/config/}" >> /etc/httpd/conf.d/variables.conf

export MANTIS_ADMINISTRATION_ENABLED=${MANTIS_ADMINISTRATION_ENABLED:-true}

if $MANTIS_ADMINISTRATION_ENABLED
then
    echo "Admin enabled."
    if [ -d "/mantis/admin/" ]
    then
        mv /mantis/admin .
    fi
else
    echo "Admin disabled."
    if [ -d "./admin/" ]
    then
        mv admin /mantis/
    fi
fi

# Values to be defined by variables
apply-parameters.sh

/usr/sbin/php-fpm &

exec /usr/sbin/httpd -D FOREGROUND
