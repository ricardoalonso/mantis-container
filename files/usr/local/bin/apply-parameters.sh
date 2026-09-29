#!/bin/bash
# Applies the tunables exposed as environment variables. Run on every start, so
# every write here has to be idempotent -- a restart re-runs it against the same
# filesystem.
set -euo pipefail

#
# replace_param <substitution_string> <file>
#
# Writes through a temp file rather than using `sed -i`. This runs as the
# `apache` user, and `sed -i` creates its temp file next to the target -- it
# cannot do that in /etc. The target files themselves are writable because the
# build chowns them to apache:0 and does `chmod g=u`.
function replace_param () {
    local tmp
    tmp=$(mktemp)
    sed "$1" "$2" > "$tmp"
    cat "$tmp" > "$2"
    rm -f "$tmp"
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

# opcache revalidation. With this Off, PHP never stats cached files again --
# faster, but a config_inc.php edit on the mounted volume then needs a restart
# to take effect.
case "${PHP_OPCACHE_VALIDATE_TIMESTAMPS:-On}" in
	[Oo]ff|0|false|no) validate=0 ;;
	*)                 validate=1 ;;
esac
replace_param "s/^opcache.validate_timestamps.*/opcache.validate_timestamps = $validate/" /etc/php.d/99-mantis.ini

# Timeout. Truncating rather than appending: with `>>` this file gained a
# duplicate Timeout directive on every container restart.
echo "Timeout $HTTPD_REQUEST_TIMEOUT" > /etc/httpd/conf.d/timeout.conf
