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

# really important, because for some reason (bug??) connections are been stuck on php-fpm
# even when they have finished their rendering at the client, causing the server to exhaust 
# it's available workers. 
replace_param "s/^max_execution_time.*/max_execution_time = $PHP_MAX_EXECUTION_TIME/" /etc/php.ini
replace_param "s/.*request_terminate_timeout =.*/request_terminate_timeout = $PHP_MAX_EXECUTION_TIME/" /etc/php-fpm.d/www.conf

# Timeout
echo "Timeout $HTTPD_REQUEST_TIMEOUT" >> /etc/httpd/conf.d/timeout.conf
