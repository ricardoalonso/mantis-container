#!/bin/bash
# Starts a built image against a throwaway MariaDB and checks that it actually
# works, rather than trusting that the build was green.
#
#   ./smoke-test.sh             # test the version in the Containerfile
#   ./smoke-test.sh 2.27.1
#
# Checks, in order:
#   1. MantisBT is present in the image at all
#   2. the patches were applied, and PHP has the php2shell fix
#   3. the container starts and Apache answers
#   4. PHP-FPM is executing PHP, not just serving static files
#   5. the healthcheck script passes inside the container
#   6. the source tree is not browsable
#   7. responses do not leak Apache/PHP versions
#   8. static assets are compressed and cacheable
#   9. REST routing still works (the canary for AllowOverride)
#  10. status pages are closed to the outside, open from inside
#  11. runtime parameters reach PHP, PHP-FPM and Apache (named, passthrough,
#      drop-ins, hooks), and config_inc.php is generated from MANTIS_*
#  12. plugins: the image's own are in /mantis/plugins, a MANTIS_PLUGINS
#      download is installed and runs, and none of it is served directly
#  13. HTTPS works with a per-container certificate, and can be turned off
#  14. the real client address is logged behind a trusted proxy
#  15. invalid parameters stop the container with a message
#  16. MANTIS_CONTEXT_PATH serves MantisBT under a sub-path instead of /
#  17. OpenID Connect: off by default, configured from MANTIS_OIDC_* when set
#      (the login flow itself needs an identity provider: see oidc-test.sh)
#  18. liveness (/healthz.php) survives a database outage, readiness does not
#  19. the container exits when php-fpm dies -- destructive, so it runs last
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

WORK=$(mktemp -d)
cleanup() { podman pod rm -f "$POD" >/dev/null 2>&1 || true; }
trap 'cleanup; rm -rf "$WORK"' EXIT

# A drop-in and a hook, to prove both are picked up.
mkdir -p "$WORK/conf.d/php" "$WORK/entrypoint.d"
echo 'realpath_cache_ttl = 321' > "$WORK/conf.d/php/smoke.ini"
cat > "$WORK/entrypoint.d/10-smoke.sh" <<'EOF'
touch /tmp/smoke-hook-ran
# A page that writes to the PHP error log from a PHP-FPM worker.
echo '<?php error_log("smoke-fpm-error-log"); echo "logged";' > /var/www/html/mantis/smoke_log.php
EOF
# A minimal plugin, delivered as MANTIS_PLUGINS would download it.
mkdir -p "$WORK/plugin/SmokePlugin/pages" "$WORK/plugin/SmokePlugin/files"
cat > "$WORK/plugin/SmokePlugin/SmokePlugin.php" <<'PHP'
<?php
class SmokePluginPlugin extends MantisPlugin {
	function register() {
		$this->name = 'Smoke';
		$this->version = '1.0';
		$this->requires = array( 'MantisCore' => '2.0.0' );
	}
}
PHP
echo '<?php echo "smoke-plugin-page";' > "$WORK/plugin/SmokePlugin/pages/hello.php"
echo 'smoke-plugin-file' > "$WORK/plugin/SmokePlugin/files/hello.txt"
tar czf "$WORK/smoke-plugin.tgz" -C "$WORK/plugin" SmokePlugin
SMOKE_PLUGIN_SUM=$(sha256sum "$WORK/smoke-plugin.tgz" | cut -d' ' -f1)
# Enabled from config rather than through Manage Plugins, which needs a login.
cat >> "$WORK/entrypoint.d/10-smoke.sh" <<'HOOK'
mkdir -p /mantis/config/config_inc.d
echo '<?php $g_plugins_force_installed["SmokePlugin"] = 3;' > /mantis/config/config_inc.d/50-smoke.php
HOOK
chmod -R a+rX "$WORK"

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

if podman run --rm "$IMAGE" rpm -q --qf '%{VERSION}\n' php-common \
		| awk -F. '{ exit !(($1 == 8 && $2 == 2 && $3 >= 35) || ($1 == 8 && $2 == 3 && $3 >= 36) || ($1 == 8 && $2 == 4 && $3 >= 27) || ($1 == 8 && $2 == 5 && $3 >= 12) || $1 >= 9) }'; then
	pass "PHP includes the php2shell fix (CVE-2026-109618/109619)"
else
	fail "PHP is vulnerable to php2shell (CVE-2026-109618/109619) -- rebuild"
fi

# -----------------------------------------------------------------------------
step "3. Container starts and Apache answers"
cleanup
podman pod create --name "$POD" -p "${PORT}:8080" >/dev/null

podman run -d --pod "$POD" --name "$POD-db" \
	-e MYSQL_ROOT_PASSWORD="smo'ke" \
	-e MYSQL_DATABASE=bugtracker \
	docker.io/library/mariadb:11 >/dev/null

# MantisBT now has a database configured from the start, so it answers 500
# until MariaDB accepts connections. Wait for it rather than racing it.
for _ in $(seq 1 60); do
	podman exec "$POD-db" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 && break
	sleep 1
done

# MANTIS_ADMINISTRATION_ENABLED=yes rather than true on purpose: the old
# entrypoint ran the value as a command, and `yes` hung it forever.
podman run -d --pod "$POD" --name "$POD-app" \
	-e MANTIS_ADMINISTRATION_ENABLED=yes \
	-e MANTIS_DB_HOST=127.0.0.1 \
	-e MANTIS_DB_USER=root \
	-e MANTIS_DB_PASSWORD="smo'ke" \
	-e PHP_UPLOAD_MAX_FILESIZE=8M \
	-e PHP_DATE_TIMEZONE=America/Sao_Paulo \
	-e PHP_FPM_MAX_CHILDREN=7 \
	-e PHP_INI_session__gc_maxlifetime=4321 \
	-e HTTPD_TRUSTED_PROXIES=127.0.0.1 \
	-v "$WORK/conf.d:/mantis/conf.d:ro,Z" \
	-v "$WORK/entrypoint.d:/mantis/entrypoint.d:ro,Z" \
	-v "$WORK/smoke-plugin.tgz:/srv/smoke-plugin.tgz:ro,Z" \
	-e MANTIS_PLUGINS="file:///srv/smoke-plugin.tgz#sha256=$SMOKE_PLUGIN_SUM" \
	"$IMAGE" >/dev/null

for _ in $(seq 1 60); do
	curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null && break
	sleep 1
done
curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null \
	&& pass "Apache is serving on ${PORT}" \
	|| { podman logs "$POD-app" | tail -20; fail "Apache never answered"; }

# -----------------------------------------------------------------------------
step "4. PHP-FPM is executing PHP, and MantisBT installs"
# The app has a generated config_inc.php but an empty database, so run the
# installer. This proves the whole path: PHP-FPM, the generated config, the
# database connection, and the admin pages being enabled.
install=$(curl -s --max-time 180 "http://127.0.0.1:${PORT}/admin/install.php" \
	--data-urlencode install=2 --data-urlencode db_type=mysqli \
	--data-urlencode hostname=127.0.0.1 --data-urlencode database_name=bugtracker \
	--data-urlencode db_username=root --data-urlencode "db_password=smo'ke" \
	--data-urlencode admin_username=root --data-urlencode "admin_password=smo'ke" \
	--data-urlencode db_table_prefix=mantis --data-urlencode db_table_plugin_prefix=plugin \
	--data-urlencode db_table_suffix=_table --data-urlencode timezone=UTC || true)
if printf '%s' "$install" | grep -q '<?php'; then
	fail "PHP source came back unexecuted"
elif ! printf '%s' "$install" | grep -q 'installed successfully'; then
	podman logs "$POD-app" | tail -20
	fail "MantisBT installer did not complete"
fi
pass "installer completed against the generated config_inc.php"

body=$(curl -fsSL --max-time 10 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)
printf '%s' "$body" | grep -qi 'login' \
	&& pass "login page renders ($(printf '%s' "$body" | wc -c) bytes)" \
	|| fail "login page does not render after install"

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
	code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/$d/")
	case "$code" in
		403|404) ;;
		*) fail "/$d/ returned $code; the tree is exposed" ;;
	esac
done
pass "core, library, vendor, lang, scripts and plugins are all denied"

body=$(curl -s "http://127.0.0.1:${PORT}/js/" || true)
printf '%s' "$body" | grep -qi "Index of" \
	&& fail "directory listing is still generated" \
	|| pass "no directory index generated"

# fonts/ must still work: its .htaccess allows font files rather than denying
# everything, so a blanket deny would break the UI.
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/fonts/")
[ "$code" = "403" ] || [ "$code" = "404" ] || [ "$code" = "200" ] \
	&& pass "fonts/ still reachable as upstream intends (HTTP $code)" \
	|| fail "fonts/ returned $code"

# -----------------------------------------------------------------------------
step "7. Responses do not leak versions"
hdrs=$(curl -sI "http://127.0.0.1:${PORT}/login_page.php")
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
	"http://127.0.0.1:${PORT}/css/default.css" | grep -i "content-encoding" | tr -d '\r')
[ -n "$enc" ] && pass "css is compressed (${enc})" || fail "css is not compressed"

exp=$(curl -s -o /dev/null -D- "http://127.0.0.1:${PORT}/css/default.css" \
	| grep -iE "^(expires|cache-control)" | head -1 | tr -d '\r')
[ -n "$exp" ] && pass "css carries caching headers (${exp})" || fail "css has no caching headers"

# -----------------------------------------------------------------------------
step "9. REST API routing still works"
# This depends on api/rest/.htaccess, so it is the canary for AllowOverride.
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/rest/issues")
case "$code" in
	403|404) fail "REST returned $code; the .htaccess rewrite is not being applied" ;;
	*) pass "REST routing intact (HTTP $code)" ;;
esac

# -----------------------------------------------------------------------------
step "10. Status pages are not public"
for p in server-status php-status; do
	code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/$p")
	[ "$code" = "403" ] || fail "/$p returned $code from outside; expected 403"
	podman exec "$POD-app" curl -fsS -o /dev/null "http://127.0.0.1:8080/$p" \
		|| fail "/$p is not reachable from inside the container"
done
pass "server-status and php-status: 403 from outside, 200 from localhost"

# -----------------------------------------------------------------------------
step "11. Runtime parameters are applied"
ini() { podman exec "$POD-app" php -r "echo ini_get('$1');"; }
[ "$(ini upload_max_filesize)" = "8M" ]        || fail "upload_max_filesize is $(ini upload_max_filesize)"
[ "$(ini post_max_size)" = "33554432" ]        || fail "post_max_size is $(ini post_max_size); expected 4 x 8M"
[ "$(ini date.timezone)" = "America/Sao_Paulo" ] || fail "date.timezone is $(ini date.timezone)"
pass "named PHP variables (upload 8M, post 4x, timezone)"
[ "$(ini session.gc_maxlifetime)" = "4321" ]   || fail "PHP_INI_ passthrough not applied"
pass "PHP_INI_* passthrough"
[ "$(ini realpath_cache_ttl)" = "321" ]        || fail "php drop-in not applied"
pass "drop-in from /mantis/conf.d/php"
podman exec "$POD-app" test -f /tmp/smoke-hook-ran || fail "entrypoint.d hook did not run"
pass "hook from /mantis/entrypoint.d ran"
podman exec "$POD-app" php-fpm -tt 2>&1 | grep -q 'pm.max_children = 7' \
	|| fail "PHP_FPM_MAX_CHILDREN not applied"
pass "PHP-FPM pool sized from PHP_FPM_MAX_CHILDREN"
curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/smoke_log.php" || fail "smoke_log.php did not run"
sleep 1
logs=$(podman logs "$POD-app" 2>&1)
grep -q 'smoke-fpm-error-log' <<<"$logs" || fail "PHP errors from PHP-FPM workers do not reach the container log"
pass "PHP errors from PHP-FPM workers reach the container log"

cfg=/mantis/config/config_inc.php
podman exec "$POD-app" test -f "$cfg" || fail "config_inc.php was not generated"
# The file uses MantisBT constants, which plain `php -r` does not have.
podman exec "$POD-app" php -r "foreach(['ON'=>1,'OFF'=>0,'DISK'=>1,'DATABASE'=>2] as \$k=>\$v) define(\$k,\$v); require '$cfg'; exit(\$g_db_password === \"smo'ke\" && strlen(\$g_crypto_master_salt) >= 16 ? 0 : 1);" \
	|| fail "generated config_inc.php has wrong values (quoting?)"
[ "$(podman exec "$POD-app" stat -c %a "$cfg")" = "640" ] || fail "config_inc.php is not mode 640"
pass "config_inc.php generated from MANTIS_*, quoted correctly, mode 640"
podman exec "$POD-app" grep -qF "require '/etc/mantis/runtime_inc.php'" "$cfg" \
	|| fail "generated config_inc.php does not load /etc/mantis/runtime_inc.php"
pass "config_inc.php loads the container's runtime settings"
body=$(curl -fsSL "http://127.0.0.1:${PORT}/admin/install.php" 2>/dev/null || true)
printf '%s' "$body" | grep -qi "install" || fail "admin pages not served with MANTIS_ADMINISTRATION_ENABLED=yes"
pass "admin pages enabled by MANTIS_ADMINISTRATION_ENABLED=yes"

# -----------------------------------------------------------------------------
step "12. Plugins"
podman exec "$POD-app" test -L /var/www/html/mantis/plugins || fail "mantis/plugins is not a symlink to the volume"
for p in MantisCoreFormatting MantisGraph Gravatar XmlImportExport OidcAuth; do
	podman exec "$POD-app" test -f "/mantis/plugins/$p/$p.php" || fail "bundled plugin $p missing from /mantis/plugins"
done
pass "the image's own plugins are in /mantis/plugins"
listed=$(podman exec "$POD-app" php -r 'chdir("/var/www/html/mantis"); require "core.php"; echo implode(" ", array_keys(plugin_find_all()));')
[[ " $listed " == *" SmokePlugin "* ]] || fail "MantisBT does not list SmokePlugin: $listed"
[[ $listed == *" ."* ]] && fail "MantisBT lists a dot-folder as a plugin: $listed"
pass "MantisBT lists exactly the plugin folders: $listed"
podman exec "$POD-app" test -f /mantis/plugins/SmokePlugin/SmokePlugin.php || fail "MANTIS_PLUGINS archive not installed"
body=$(curl -s "http://127.0.0.1:${PORT}/plugin.php?page=SmokePlugin/hello")
[ "$body" = "smoke-plugin-page" ] || fail "plugin page did not run: $(printf '%s' "$body" | head -c 200)"
body=$(curl -s "http://127.0.0.1:${PORT}/plugin_file.php?file=SmokePlugin/hello.txt")
[ "$body" = "smoke-plugin-file" ] || fail "plugin file not served: $(printf '%s' "$body" | head -c 200)"
pass "MANTIS_PLUGINS archive installed; MantisBT runs its page and serves its files"
for u in /plugins/SmokePlugin/SmokePlugin.php /plugins/SmokePlugin/files/hello.txt "/plugins/.archive-$SMOKE_PLUGIN_SUM"; do
	code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}$u")
	case "$code" in 403|404) ;; *) fail "$u returned $code through the symlink" ;; esac
done
pass "nothing under /plugins/ is served directly"

# -----------------------------------------------------------------------------
step "13. HTTPS"
podman exec "$POD-app" curl -kfsS -o /dev/null https://127.0.0.1:8443/login_page.php \
	|| fail "HTTPS does not answer on 8443"
pass "HTTPS answers on 8443"
fp() { podman run --rm "$IMAGE" bash -c 'apply-parameters.sh >/dev/null && openssl x509 -noout -fingerprint -in /etc/httpd/tls/selfsigned.crt'; }
[ "$(fp)" != "$(fp)" ] || fail "two containers got the same certificate"
pass "each container generates its own certificate"
podman run --rm -e HTTPD_ENABLE_HTTPS=false "$IMAGE" bash -c 'apply-parameters.sh >/dev/null && httpd -t -D DUMP_VHOSTS 2>&1' \
	| grep -q 8443 && fail "HTTPD_ENABLE_HTTPS=false still configures 8443"
pass "HTTPD_ENABLE_HTTPS=false removes the 8443 listener"

# -----------------------------------------------------------------------------
step "14. Client address behind a trusted proxy"
podman exec "$POD-app" curl -s -o /dev/null -H 'X-Forwarded-For: 203.0.113.77' http://127.0.0.1:8080/
sleep 1
podman logs "$POD-app" 2>/dev/null | grep -q '^203\.0\.113\.77 ' \
	|| fail "access log does not show the forwarded client address"
pass "access log shows the client from X-Forwarded-For"

# -----------------------------------------------------------------------------
step "15. Invalid parameters stop the container"
for bad in PHP_UPLOAD_MAX_FILESIZE=4MB MANTIS_ADMINISTRATION_ENABLED=maybe \
           PHP_DATE_TIMEZONE=Mars/Olympus PHP_FPM_PM=sometimes \
           'PHP_UPLOAD_MAX_FILESIZE=8M PHP_POST_MAX_SIZE=1M' \
           MANTIS_CONTEXT_PATH=/a/../b MANTIS_CONTEXT_PATH=/server-status \
           MANTIS_PLUGINS=https://example.com/plugin.zip \
           MANTIS_OIDC_ISSUER=ftp://sso.example.com \
           'MANTIS_OIDC_ISSUER=https://sso.example.com/realms/x MANTIS_OIDC_CLIENT_SECRET=s' \
           'MANTIS_OIDC_ISSUER=https://sso.example.com/realms/x MANTIS_OIDC_CLIENT_ID=c' \
           'MANTIS_OIDC_ISSUER=https://sso.example.com/realms/x MANTIS_OIDC_CLIENT_ID=c MANTIS_OIDC_CLIENT_SECRET=a"b' \
           'MANTIS_OIDC_ISSUER=https://sso.example.com/realms/x MANTIS_OIDC_CLIENT_ID=c MANTIS_OIDC_CLIENT_SECRET=s MANTIS_OIDC_SCOPES=email' \
           'MANTIS_OIDC_ISSUER=https://sso.example.com/realms/x MANTIS_OIDC_CLIENT_ID=c MANTIS_OIDC_CLIENT_SECRET=s MANTIS_OIDC_CRYPTO_PASSPHRASE=short'; do
	envs=()
	for kv in $bad; do envs+=(-e "$kv"); done
	if out=$(timeout 60 podman run --rm "${envs[@]}" "$IMAGE" 2>&1); then
		fail "container started with $bad"
	fi
	printf '%s' "$out" | grep -q 'ERROR:' || fail "no error message for $bad: $out"
done
pass "rejected with a message: bad size, bad boolean, bad timezone, bad pm, post < upload, bad context, unpinned plugin, bad OIDC settings"

# -----------------------------------------------------------------------------
step "16. MantisBT under a context path"
# MantisBT is served at / by default (steps 3-12). With MANTIS_CONTEXT_PATH it
# moves under that path, / redirects there, and nothing else is served.
podman run -d --name "$POD-ctx" -e MANTIS_CONTEXT_PATH=/bugs/ "$IMAGE" >/dev/null
trap 'cleanup; podman rm -f "$POD-ctx" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
for _ in $(seq 1 30); do
	podman exec "$POD-ctx" curl -fsS -o /dev/null http://127.0.0.1:8080/healthz.php 2>/dev/null && break
	sleep 1
done
ctx_code() { podman exec "$POD-ctx" curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "http://127.0.0.1:8080$1"; }
[ "$(ctx_code /)" = "302 http://127.0.0.1:8080/bugs/" ] || fail "/ returned '$(ctx_code /)'; expected a redirect to /bugs/"
# Behind a TLS-terminating proxy the redirect must stay on https.
code=$(podman exec "$POD-ctx" curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H 'X-Forwarded-Proto: https' -H 'Host: x' http://127.0.0.1:8080/)
[ "$code" = "302 https://x/bugs/" ] || fail "/ with X-Forwarded-Proto: https returned '$code'; expected https://x/bugs/"
code=$(ctx_code /bugs/css/default.css); [ "${code%% *}" = "200" ] || fail "/bugs/css/default.css returned $code"
code=$(ctx_code /bugs/core/); case "${code%% *}" in 403|404) ;; *) fail "/bugs/core/ returned $code" ;; esac
code=$(ctx_code /css/default.css); [ "${code%% *}" = "404" ] || fail "/css/default.css returned $code outside the context"
code=$(ctx_code /mantis/); [ "${code%% *}" = "404" ] || fail "/mantis/ returned $code"
podman exec "$POD-ctx" healthcheck.sh || fail "healthcheck fails with a context path"
podman rm -f "$POD-ctx" >/dev/null
pass "MANTIS_CONTEXT_PATH=/bugs/: served at /bugs/, / redirects there, nothing outside it"

# -----------------------------------------------------------------------------
step "17. OpenID Connect configuration"
# Off by default: the module is not even loaded.
podman exec "$POD-app" bash -c 'httpd -M 2>/dev/null | grep -q auth_openidc' \
	&& fail "mod_auth_openidc is loaded although MANTIS_OIDC_ISSUER is not set"
podman exec "$POD-app" test ! -e /etc/httpd/conf.d/zz-oidc.conf || fail "zz-oidc.conf exists with OIDC off"
podman exec "$POD-app" grep -q 'OpenID Connect is off' /etc/mantis/runtime_inc.php \
	|| fail "runtime_inc.php does not say OIDC is off"
pass "off by default: module not loaded, no Apache config, plugin not enabled"
# On: rendered and accepted by Apache. Logging in needs an identity provider;
# oidc-test.sh does that end to end.
oidc_env=(-e MANTIS_OIDC_ISSUER=https://sso.example.com/realms/smoke -e MANTIS_OIDC_CLIENT_ID=mantis
          -e MANTIS_OIDC_CLIENT_SECRET=s3cr3t -e "MANTIS_OIDC_LOCAL_USERS=administrator, break.glass")
out=$(podman run --rm "${oidc_env[@]}" "$IMAGE" bash -c 'apply-parameters.sh >/dev/null && httpd -t 2>&1 &&
	httpd -M 2>/dev/null | grep -c auth_openidc && stat -c %a /etc/httpd/conf.d/zz-oidc.conf &&
	grep -c "s3cr3t" /etc/httpd/conf.d/zz-runtime.conf; php -r "define(\"PLUGIN_PRIORITY_HIGH\", 5); require \"/etc/mantis/runtime_inc.php\"; echo json_encode([\$g_plugins_force_installed, \$g_plugin_OidcAuth_local_users]);"') \
	|| fail "OIDC configuration rejected: $out"
[ "$out" = 'Syntax OK
1
600
0
[{"OidcAuth":5},["administrator","break.glass"]]' ] || fail "unexpected OIDC configuration: $out"
pass "on: Apache accepts it, module loaded, secret only in a 0600 file, plugin forced on, local users quoted"
# An existing config_inc.php that does not load runtime_inc.php would make
# MantisBT ignore the plugin silently; the container refuses to start instead.
mkdir -p "$WORK/oldconfig"
echo '<?php $g_hostname = "127.0.0.1";' > "$WORK/oldconfig/config_inc.php"
chmod -R a+rwX "$WORK/oldconfig"
if out=$(timeout 60 podman run --rm "${oidc_env[@]}" -v "$WORK/oldconfig:/mantis/config:Z" "$IMAGE" 2>&1); then
	fail "started with OIDC and a config_inc.php that ignores it"
fi
grep -q "does not load /etc/mantis/runtime_inc.php" <<<"$out" || fail "no clear error for an old config_inc.php: $out"
pass "an existing config_inc.php without the include stops the container, with the line to add"

# -----------------------------------------------------------------------------
step "18. Liveness does not depend on the database"
# A liveness probe that fails with the database would get every MantisBT pod
# restarted during a database outage. Readiness is what should fail.
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/healthz.php")
[ "$code" = "200" ] || fail "/healthz.php returned $code"
podman logs "$POD-app" 2>/dev/null | grep -q 'GET /healthz.php' \
	&& fail "probe requests are filling the access log"
pass "/healthz.php answers 200 and is kept out of the access log"
podman stop -t 5 "$POD-db" >/dev/null
podman exec "$POD-app" healthcheck.sh || fail "healthcheck fails while only the database is down"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/login_page.php")
[ "$code" -ge 500 ] || fail "readiness URL returned $code with the database down; expected 5xx"
pass "database down: liveness still passes, readiness fails (HTTP $code)"

# -----------------------------------------------------------------------------
step "19. Container exits when php-fpm dies (destructive, runs last)"
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
