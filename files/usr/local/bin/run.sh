#!/bin/bash
# Container entrypoint: apply runtime configuration, then supervise php-fpm and
# httpd together.
#
# Order of startup:
#   1. apply-parameters.sh   PHP / PHP-FPM / Apache settings and drop-ins
#   2. mantis-config.sh      config_inc.php from MANTIS_*, if none exists yet
#      install-plugins.sh    /mantis/plugins: bundled, MANTIS_PLUGINS, your own
#   3. admin pages           enabled or disabled
#   4. /mantis/entrypoint.d  site hooks
#   5. config test           php, php-fpm -t, httpd -t
#   6. start and supervise
set -euo pipefail

# shellcheck source=../lib/mantis/common.sh
source /usr/local/lib/mantis/common.sh
set_defaults

MANTIS_DIR=/var/www/html/mantis
HOOK_DIR=/mantis/entrypoint.d

apply-parameters.sh
mantis-config.sh
install-plugins.sh

# -----------------------------------------------------------------------------
# Admin pages. Upstream's advice is to remove admin/ once installed, so it is
# off by default and moved out of the document root when disabled. Turn it on
# for the installer or a schema upgrade, then off again.
if is_true MANTIS_ADMINISTRATION_ENABLED; then
	[ -d /mantis/admin ] && mv /mantis/admin "$MANTIS_DIR/"
	log "Admin pages enabled at $(context_path)/admin/. Disable them again once you are done."
else
	[ -d "$MANTIS_DIR/admin" ] && mv "$MANTIS_DIR/admin" /mantis/
	log "Admin pages disabled."
fi

# -----------------------------------------------------------------------------
# Site hooks, in name order. A failing hook stops the container: a hook exists
# because something has to be true before MantisBT starts.
if [ -d "$HOOK_DIR" ]; then
	for hook in "$HOOK_DIR"/*.sh; do
		[ -e "$hook" ] || continue
		log "Running hook $hook"
		bash "$hook" || die "hook $hook failed (exit $?)"
	done
fi

# -----------------------------------------------------------------------------
# Config test. A bad value or drop-in stops the container here, with the
# reason, instead of starting half configured.
out=$(php -r 'exit(0);' 2>&1) || die "PHP does not start:"$'\n'"$out"
if [ -n "$out" ]; then
	if grep -qiE 'syntax error|parse error' <<<"$out"; then
		die "PHP configuration is invalid:"$'\n'"$out"
	fi
	warn "PHP reported at startup:"$'\n'"$out"
fi
out=$(php-fpm -t 2>&1) || die "PHP-FPM configuration is invalid:"$'\n'"$out"
out=$(httpd -t 2>&1)   || die "Apache configuration is invalid:"$'\n'"$out"

# -----------------------------------------------------------------------------
# Supervise both processes. `wait -n` returns as soon as either exits; we then
# stop the other and exit non-zero, so a restart policy -- including
# on-failure -- recovers the container. Otherwise a dead php-fpm left the
# container "up" and serving 502s.
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
