#!/bin/bash
# Starts a built image against a throwaway MariaDB and checks that it actually
# works, rather than trusting that the build was green.
#
#   ./smoke-test.sh             # test the version in the Containerfile
#   ./smoke-test.sh 2.27.1
#
# Checks, in order:
#   1. MantisBT is present in the image at all
#   2. the patches were applied
#   3. the container starts and Apache answers
#   4. PHP-FPM is executing PHP, not just serving static files
#   5. the healthcheck script passes inside the container
#   6. the source tree is not browsable
#   7. responses do not leak Apache/PHP versions
#   8. static assets are compressed and cacheable
#   9. REST routing still works (the canary for AllowOverride)
#  10. the container exits when php-fpm dies -- destructive, so it runs last
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

REGISTRY=${REGISTRY:-quay.io/ricardoalonsos/mantis}
VERSION=${1:-$(sed -n 's/^ARG MANTIS_VERSION=\(.*\)$/\1/p' Containerfile)}
IMAGE="${REGISTRY}:${VERSION}"
POD=mantis-smoke
PORT=18080

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

cleanup() { podman pod rm -f "$POD" >/dev/null 2>&1 || true; }
trap cleanup EXIT

podman image exists "$IMAGE" || fail "$IMAGE is not built. Run ./build.sh $VERSION"

# -----------------------------------------------------------------------------
step "1. MantisBT present in the image"
podman run --rm "$IMAGE" test -f /var/www/html/mantis/index.php \
	&& pass "mantis/index.php exists" \
	|| fail "image contains no MantisBT"

# -----------------------------------------------------------------------------
step "2. Patches applied"
if podman run --rm "$IMAGE" grep -q 'file_upload_subdirectory_depth' \
		/var/www/html/mantis/config_defaults_inc.php; then
	pass "subdirectory settings present in config_defaults_inc.php"
else
	fail "patched settings missing -- patches did not apply"
fi

if podman run --rm "$IMAGE" grep -q 'file_get_disk_path' \
		/var/www/html/mantis/file_download.php; then
	pass "file_download.php carries the attachment path fix"
else
	fail "file_download.php is unpatched"
fi

# -----------------------------------------------------------------------------
step "3. Container starts and Apache answers"
cleanup
podman pod create --name "$POD" -p "${PORT}:8080" >/dev/null

podman run -d --pod "$POD" --name "$POD-db" \
	-e MYSQL_ROOT_PASSWORD=smoke \
	-e MYSQL_DATABASE=bugtracker \
	docker.io/library/mariadb:11 >/dev/null

podman run -d --pod "$POD" --name "$POD-app" "$IMAGE" >/dev/null

for _ in $(seq 1 60); do
	curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null && break
	sleep 1
done
curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null \
	&& pass "Apache is serving on ${PORT}" \
	|| { podman logs "$POD-app" | tail -20; fail "Apache never answered"; }

# -----------------------------------------------------------------------------
step "4. PHP-FPM is executing PHP"
# Without a config_inc.php MantisBT sends you to the installer. Either way the
# response has to come from PHP -- a 502 means php-fpm is not wired up, and
# seeing raw '<?php' back means PHP is not executing at all.
body=$(curl -fsSL --max-time 10 "http://127.0.0.1:${PORT}/mantis/" 2>/dev/null || true)
if [ -z "$body" ]; then
	podman logs "$POD-app" | tail -20
	fail "no response from the PHP entry point"
elif printf '%s' "$body" | grep -q '<?php'; then
	fail "PHP source came back unexecuted"
else
	pass "PHP is executing (response is $(printf '%s' "$body" | wc -c) bytes of output)"
fi

# -----------------------------------------------------------------------------
step "5. Healthcheck script"
if podman exec "$POD-app" healthcheck.sh >/dev/null 2>&1; then
	pass "healthcheck.sh succeeds"
else
	fail "healthcheck.sh failed inside a healthy container"
fi

# -----------------------------------------------------------------------------
step "6. Source tree is not browsable"
for d in core library vendor lang scripts plugins; do
	code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/mantis/$d/")
	case "$code" in
		403|404) ;;
		*) fail "/mantis/$d/ returned $code; the tree is exposed" ;;
	esac
done
pass "core, library, vendor, lang, scripts and plugins are all denied"

body=$(curl -s "http://127.0.0.1:${PORT}/mantis/js/" || true)
printf '%s' "$body" | grep -qi "Index of" \
	&& fail "directory listing is still generated" \
	|| pass "no directory index generated"

# fonts/ must still work: its .htaccess allows font files rather than denying
# everything, so a blanket deny would break the UI.
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/mantis/fonts/")
[ "$code" = "403" ] || [ "$code" = "404" ] || [ "$code" = "200" ] \
	&& pass "fonts/ still reachable as upstream intends (HTTP $code)" \
	|| fail "fonts/ returned $code"

# -----------------------------------------------------------------------------
step "7. Responses do not leak versions"
hdrs=$(curl -sI "http://127.0.0.1:${PORT}/mantis/login_page.php")
printf '%s' "$hdrs" | grep -qi "^X-Powered-By" \
	&& fail "X-Powered-By still present" \
	|| pass "no X-Powered-By header"
server=$(printf '%s' "$hdrs" | grep -i "^Server:" | tr -d '\r')
printf '%s' "$server" | grep -qiE "[0-9]+\.[0-9]+" \
	&& fail "Server header still carries a version: $server" \
	|| pass "Server header is bare (${server:-none})"

# -----------------------------------------------------------------------------
step "8. Static assets are compressed and cacheable"
enc=$(curl -s -H 'Accept-Encoding: gzip' -o /dev/null -D- \
	"http://127.0.0.1:${PORT}/mantis/css/default.css" | grep -i "content-encoding" | tr -d '\r')
[ -n "$enc" ] && pass "css is compressed (${enc})" || fail "css is not compressed"

exp=$(curl -s -o /dev/null -D- "http://127.0.0.1:${PORT}/mantis/css/default.css" \
	| grep -iE "^(expires|cache-control)" | head -1 | tr -d '\r')
[ -n "$exp" ] && pass "css carries caching headers (${exp})" || fail "css has no caching headers"

# -----------------------------------------------------------------------------
step "9. REST API routing still works"
# This depends on api/rest/.htaccess, so it is the canary for AllowOverride.
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/mantis/api/rest/issues")
case "$code" in
	403|404) fail "REST returned $code; the .htaccess rewrite is not being applied" ;;
	*) pass "REST routing intact (HTTP $code)" ;;
esac

# -----------------------------------------------------------------------------
step "10. Container exits when php-fpm dies (destructive, runs last)"
# The old entrypoint exec'd httpd and backgrounded php-fpm, so a dead php-fpm
# left the container 'up' and serving 502s indefinitely.
podman exec "$POD-app" pkill -TERM -x php-fpm \
	|| fail "could not signal php-fpm (is procps-ng installed?)"
for _ in $(seq 1 20); do
	state=$(podman inspect "$POD-app" --format '{{.State.Status}}' 2>/dev/null || echo gone)
	[ "$state" = "running" ] || break
	sleep 1
done
state=$(podman inspect "$POD-app" --format '{{.State.Status}}' 2>/dev/null || echo gone)
if [ "$state" = "running" ]; then
	fail "container still running after php-fpm was killed"
fi
code=$(podman inspect "$POD-app" --format '{{.State.ExitCode}}' 2>/dev/null || echo "?")
if [ "$code" = "0" ]; then
	fail "container exited 0, which --restart on-failure would ignore"
fi
pass "container stopped (state: $state, exit $code), so a restart policy recovers it"

printf '\n\033[32mAll smoke tests passed for %s\033[0m\n' "$IMAGE"
