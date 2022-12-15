#!/bin/bash

#
# replace_para <substitution_string> <file>
# 
function replace_param () {
    sed "$1" $2 > /tmp/sed.out 
    cat /tmp/sed.out > $2
    rm -f /tmp/sed.out
}

# Values to be defined by variables
replace_param "s/^display_errors.*/display_errors = $PHP_DISPLAY_ERRORS/" /etc/php.ini
replace_param "s/^upload_max_filesize.*/upload_max_filesize = $PHP_UPLOAD_MAX_FILESIZE/" /etc/php.ini
replace_param "s/^post_max_size.*/post_max_size = $PHP_UPLOAD_MAX_FILESIZE/" /etc/php.ini
replace_param "s/^memory_limit.*/memory_limit = $PHP_MEMORY_LIMIT/" /etc/php.ini

# Timeout
echo "Timeout $REQUEST_TIMEOUT" >> /etc/httpd/conf.d/timeout.conf
