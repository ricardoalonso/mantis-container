#!/bin/bash
# Container entrypoint: apply runtime configuration, then supervise php-fpm and
# httpd together.
set -euo pipefail

# Truncating rather than appending: `podman restart` re-runs this script against
# the same filesystem, so `>>` grew these files by a line on every restart.
echo "SetEnv MANTIS_CONFIG_FOLDER ${MANTIS_CONFIG_FOLDER:-/mantis/config/}" > /etc/httpd/conf.d/variables.conf

export MANTIS_ADMINISTRATION_ENABLED=${MANTIS_ADMINISTRATION_ENABLED:-true}

if $MANTIS_ADMINISTRATION_ENABLED
then
    echo "Admin enabled."
    if [ -d "/mantis/admin/" ]
    then
        mv /mantis/admin mantis/
    fi
else
    echo "Admin disabled."
    if [ -d "mantis/admin/" ]
    then
        mv mantis/admin /mantis/
    fi
fi

# Values to be defined by variables
apply-parameters.sh

# -----------------------------------------------------------------------------
# Supervise both processes. Previously php-fpm was backgrounded and httpd was
# exec'd, so php-fpm dying left the container "up" but serving 502s until
# somebody noticed. `wait -n` returns as soon as either exits; we then stop the
# other and exit non-zero, so a restart policy -- including on-failure --
# recovers the container.
php_fpm_pid=""
httpd_pid=""
terminating=0

stop_children() {
	[ -n "$httpd_pid" ] && kill -TERM "$httpd_pid" 2>/dev/null || true
	[ -n "$php_fpm_pid" ] && kill -TERM "$php_fpm_pid" 2>/dev/null || true
	wait 2>/dev/null || true
}

on_signal() {
	terminating=1
	trap - TERM INT
	stop_children
	exit 0
}
trap on_signal TERM INT

/usr/sbin/php-fpm &
php_fpm_pid=$!

/usr/sbin/httpd -D FOREGROUND &
httpd_pid=$!

# `set -e` would abort on a non-zero child, which is the case we handle here.
set +e
wait -n
status=$?
set -e

# Asked to stop from outside: that is a clean shutdown.
[ "$terminating" = "1" ] && exit 0

if ! kill -0 "$php_fpm_pid" 2>/dev/null; then
	echo "php-fpm exited unexpectedly (status $status); stopping container" >&2
else
	echo "httpd exited unexpectedly (status $status); stopping container" >&2
fi

stop_children

# A managed process exiting on its own is a container failure even when it
# exited cleanly, so never report success here.
[ "$status" -eq 0 ] && status=1
exit "$status"
