#!/bin/bash
# Applies the runtime parameters to PHP, PHP-FPM and Apache.
#
# Every value is validated first, then written to an override file that is
# regenerated from scratch on each start:
#
#   /etc/php.d/zz-runtime.ini            PHP_* and PHP_INI_*
#   /etc/php-fpm.d/zz-runtime.conf       PHP_FPM_* and PHP_FPM_POOL_*
#   /etc/httpd/conf.d/zz-runtime.conf    HTTPD_*
#   /etc/httpd/conf.d/zz-oidc.conf       MANTIS_OIDC_* (only when enabled)
#   /etc/mantis/runtime_inc.php          MANTIS_OIDC_*, for MantisBT
#
# followed by the files from the /mantis/conf.d drop-in directories. Nothing
# edits the distribution's own files in place any more: the old `sed` approach
# silently did nothing when a line it expected was missing or commented, and
# broke on values containing `/` or `&`. Rewriting whole files also makes a
# restart idempotent by construction.
#
# Runs as `apache`; the build makes these directories writable for it.
set -euo pipefail

# shellcheck source=../lib/mantis/common.sh
source /usr/local/lib/mantis/common.sh
set_defaults

PHP_RUNTIME=/etc/php.d/zz-runtime.ini
FPM_RUNTIME=/etc/php-fpm.d/zz-runtime.conf
HTTPD_RUNTIME=/etc/httpd/conf.d/zz-runtime.conf
OIDC_RUNTIME=/etc/httpd/conf.d/zz-oidc.conf
TLS_DIR=/etc/httpd/tls
DROPIN_DIR=/mantis/conf.d

# =============================================================================
# Validation. All of it happens before anything is written, so a typo stops the
# container with a message instead of leaving it half configured.
# =============================================================================

for v in PHP_UPLOAD_MAX_FILESIZE PHP_MEMORY_LIMIT; do
	[ "$v" = PHP_MEMORY_LIMIT ] && [ "$PHP_MEMORY_LIMIT" = "-1" ] && continue
	require_size "$v"
done

# post_max_size has to exceed upload_max_filesize: MantisBT sends every file
# attached to an issue in one POST. Default to room for four files.
upload_bytes=$(size_to_bytes "$PHP_UPLOAD_MAX_FILESIZE")
if [ -z "$PHP_POST_MAX_SIZE" ]; then
	PHP_POST_MAX_SIZE=$(( upload_bytes * 4 ))
else
	require_size PHP_POST_MAX_SIZE
fi
post_bytes=$(size_to_bytes "$PHP_POST_MAX_SIZE")
(( post_bytes >= upload_bytes )) \
	|| die "PHP_POST_MAX_SIZE ($PHP_POST_MAX_SIZE) is smaller than PHP_UPLOAD_MAX_FILESIZE ($PHP_UPLOAD_MAX_FILESIZE); no upload would ever succeed"

require_match PHP_DISPLAY_ERRORS '^([Oo][Nn]|[Oo][Ff][Ff]|stderr|stdout|0|1)$' "On, Off, stderr or stdout"
require_match PHP_ERROR_REPORTING '^[A-Z_0-9 &|~^()-]+$' "an expression such as 'E_ALL & ~E_DEPRECATED'"
require_int PHP_MAX_EXECUTION_TIME 0
require_int PHP_MAX_INPUT_TIME 0
require_int PHP_MAX_INPUT_VARS 1
require_bool PHP_OPCACHE_VALIDATE_TIMESTAMPS

# Checked against PHP's own list rather than a regex, so "America/Sao_paulo" is
# caught here instead of becoming a warning on every request.
php -r 'exit(in_array($argv[1], timezone_identifiers_list(), true) ? 0 : 1);' -- "$PHP_DATE_TIMEZONE" \
	|| die "PHP_DATE_TIMEZONE='$PHP_DATE_TIMEZONE' is not a known timezone (example: America/Sao_Paulo)"

# --- PHP-FPM pool ------------------------------------------------------------
require_match PHP_FPM_PM '^(static|dynamic|ondemand)$' "static, dynamic or ondemand"
require_int PHP_FPM_MAX_CHILDREN 1
require_int PHP_FPM_MAX_REQUESTS 0
require_int PHP_FPM_REQUEST_TERMINATE_TIMEOUT 0
require_match PHP_FPM_PROCESS_IDLE_TIMEOUT '^[0-9]+[smhd]?$' "a duration such as 10s"

# The spare-server defaults are derived from max_children, so lowering
# PHP_FPM_MAX_CHILDREN alone never produces a pool FPM refuses to start.
if [ "$PHP_FPM_PM" = dynamic ]; then
	: "${PHP_FPM_MAX_SPARE_SERVERS:=$(( PHP_FPM_MAX_CHILDREN < 8 ? PHP_FPM_MAX_CHILDREN : 8 ))}"
	: "${PHP_FPM_START_SERVERS:=$(( PHP_FPM_MAX_SPARE_SERVERS < 4 ? PHP_FPM_MAX_SPARE_SERVERS : 4 ))}"
	: "${PHP_FPM_MIN_SPARE_SERVERS:=$(( PHP_FPM_START_SERVERS / 2 > 0 ? PHP_FPM_START_SERVERS / 2 : 1 ))}"
	require_int PHP_FPM_START_SERVERS 1
	require_int PHP_FPM_MIN_SPARE_SERVERS 1
	require_int PHP_FPM_MAX_SPARE_SERVERS 1
	(( PHP_FPM_MIN_SPARE_SERVERS <= PHP_FPM_START_SERVERS \
	   && PHP_FPM_START_SERVERS <= PHP_FPM_MAX_SPARE_SERVERS \
	   && PHP_FPM_MAX_SPARE_SERVERS <= PHP_FPM_MAX_CHILDREN )) \
		|| die "PHP-FPM needs MIN_SPARE_SERVERS ($PHP_FPM_MIN_SPARE_SERVERS) <= START_SERVERS ($PHP_FPM_START_SERVERS) <= MAX_SPARE_SERVERS ($PHP_FPM_MAX_SPARE_SERVERS) <= MAX_CHILDREN ($PHP_FPM_MAX_CHILDREN)"
fi

# Worst case is every worker at memory_limit at once. Only a warning: real
# usage is far lower, but this is how a container gets OOM-killed under load.
if [ "$PHP_MEMORY_LIMIT" != "-1" ] && [ -r /sys/fs/cgroup/memory.max ]; then
	cgroup_max=$(</sys/fs/cgroup/memory.max)
	if [[ $cgroup_max =~ ^[0-9]+$ ]]; then
		worst=$(( $(size_to_bytes "$PHP_MEMORY_LIMIT") * PHP_FPM_MAX_CHILDREN ))
		(( worst <= cgroup_max )) \
			|| warn "PHP_FPM_MAX_CHILDREN ($PHP_FPM_MAX_CHILDREN) x PHP_MEMORY_LIMIT ($PHP_MEMORY_LIMIT) exceeds the container memory limit ($(( cgroup_max / 1024 / 1024 ))M)"
	fi
fi

# --- Apache ------------------------------------------------------------------
require_match HTTPD_SERVER_NAME '^[A-Za-z0-9.-]+(:[0-9]+)?$' "a hostname, optionally with :port"
require_int HTTPD_REQUEST_TIMEOUT 1
require_match HTTPD_LOG_LEVEL '^[a-z0-9_:. ]+$' "a LogLevel such as warn, info or 'warn ssl:info'"
require_match HTTPD_REMOTEIP_HEADER '^[A-Za-z0-9-]+$' "a header name"
require_match HTTPD_TRUSTED_PROXIES '^[0-9A-Fa-f:./, ]*$' "IP addresses or CIDR ranges, separated by spaces or commas"
require_match HTTPD_STATUS_ALLOW '^(local|all|none|[0-9A-Fa-f:./, ]+)$' "local, all, none, or IP addresses / CIDR ranges"
require_bool HTTPD_ENABLE_HTTPS

# --- MantisBT URL ------------------------------------------------------------
require_match MANTIS_CONTEXT_PATH '^/?([A-Za-z0-9._~-]+/?)*$' "a URL path such as / or /mantis"
context=$(context_path)
case "$context/" in
	*/./*|*/../*) die "MANTIS_CONTEXT_PATH='$MANTIS_CONTEXT_PATH' must not contain . or .. segments" ;;
	/healthz.php/*|/server-status/*|/php-status/*)
		die "MANTIS_CONTEXT_PATH='$MANTIS_CONTEXT_PATH' clashes with a URL the container already serves" ;;
esac

if (( HTTPD_REQUEST_TIMEOUT < PHP_FPM_REQUEST_TERMINATE_TIMEOUT )); then
	warn "HTTPD_REQUEST_TIMEOUT ($HTTPD_REQUEST_TIMEOUT) is shorter than PHP_FPM_REQUEST_TERMINATE_TIMEOUT ($PHP_FPM_REQUEST_TERMINATE_TIMEOUT): Apache will give up on requests PHP is still working on"
fi

# --- OpenID Connect ----------------------------------------------------------
# Values end up inside double-quoted Apache arguments, where ", \ and $ (env
# expansion) are special, so those are refused rather than escaped.
file_env MANTIS_OIDC_CLIENT_SECRET
file_env MANTIS_OIDC_CRYPTO_PASSPHRASE
oidc_local_users=()
if [ -n "$MANTIS_OIDC_ISSUER" ]; then
	require_match MANTIS_OIDC_ISSUER '^https?://[^[:space:]"\\$]+$' "the issuer URL, e.g. https://sso.example.com/realms/mantis"
	[ -n "${MANTIS_OIDC_CLIENT_ID:-}" ] || die "MANTIS_OIDC_ISSUER is set, so MANTIS_OIDC_CLIENT_ID is required"
	require_match MANTIS_OIDC_CLIENT_ID '^[A-Za-z0-9._:@/+-]+$' "a client id (letters, digits and ._:@/+-)"
	[ -n "${MANTIS_OIDC_CLIENT_SECRET:-}" ] || die "MANTIS_OIDC_ISSUER is set, so MANTIS_OIDC_CLIENT_SECRET (or _FILE) is required"
	require_match MANTIS_OIDC_CLIENT_SECRET '^[^"\\$[:cntrl:]]+$' "a secret without \", \\, \$ or control characters"
	require_match MANTIS_OIDC_SCOPES '^[A-Za-z0-9_.:/ -]+$' "space-separated scopes, e.g. 'openid email profile'"
	[[ " $MANTIS_OIDC_SCOPES " == *" openid "* ]] || die "MANTIS_OIDC_SCOPES='$MANTIS_OIDC_SCOPES' must include openid"
	require_match MANTIS_OIDC_USERNAME_CLAIM '^[A-Za-z0-9_.:-]+$' "a claim name such as preferred_username, email or sub"
	require_match MANTIS_OIDC_LOCAL_USERS '^[A-Za-z0-9 ._@+,-]+$' "comma-separated usernames, or none"
	if [ "${MANTIS_OIDC_LOCAL_USERS,,}" != none ]; then
		IFS=, read -ra users <<<"$MANTIS_OIDC_LOCAL_USERS"
		for u in "${users[@]}"; do
			u=${u#"${u%%[! ]*}"}
			u=${u%"${u##*[! ]}"}
			[ -n "$u" ] && oidc_local_users+=("$u")
		done
	fi
	if [ -n "${MANTIS_OIDC_CRYPTO_PASSPHRASE:-}" ]; then
		require_match MANTIS_OIDC_CRYPTO_PASSPHRASE '^[^"\\$[:cntrl:]]{32,}$' "at least 32 characters, without \", \\, \$ or control characters"
	else
		# Encrypts mod_auth_openidc's cookies. A new one on every start only
		# costs logins in progress during a restart; with several replicas it
		# must be shared, and is then required (see README-authentication.md).
		MANTIS_OIDC_CRYPTO_PASSPHRASE=$(openssl rand -hex 32)
	fi
else
	for v in MANTIS_OIDC_CLIENT_ID MANTIS_OIDC_CLIENT_SECRET MANTIS_OIDC_CRYPTO_PASSPHRASE; do
		[ -z "${!v:-}" ] || warn "$v is set but MANTIS_OIDC_ISSUER is not: OpenID Connect stays off"
	done
fi

if [ -n "$HTTPD_TLS_CERT_FILE$HTTPD_TLS_KEY_FILE" ]; then
	[ -n "$HTTPD_TLS_CERT_FILE" ] && [ -n "$HTTPD_TLS_KEY_FILE" ] \
		|| die "set both HTTPD_TLS_CERT_FILE and HTTPD_TLS_KEY_FILE, or neither"
	[ -r "$HTTPD_TLS_CERT_FILE" ] || die "HTTPD_TLS_CERT_FILE=$HTTPD_TLS_CERT_FILE is not readable"
	[ -r "$HTTPD_TLS_KEY_FILE" ]  || die "HTTPD_TLS_KEY_FILE=$HTTPD_TLS_KEY_FILE is not readable"
fi

# --- Passthrough variables ---------------------------------------------------
# PHP_INI_<key> and PHP_FPM_POOL_<key>, where "__" stands for ".", because a
# dot cannot appear in a shell variable name:
#   PHP_INI_session__gc_maxlifetime=7200  ->  session.gc_maxlifetime = 7200
php_ini_extra=()
fpm_pool_extra=()
for name in $(compgen -e); do
	case "$name" in
		PHP_INI_*)      prefix=PHP_INI_ ;;
		PHP_FPM_POOL_*) prefix=PHP_FPM_POOL_ ;;
		*) continue ;;
	esac
	key=${name#"$prefix"}
	key=${key//__/.}
	[[ $key =~ ^[A-Za-z0-9_.]+$ ]] || die "$name does not map to a valid setting name"
	require_one_line "$name"
	if [ "$prefix" = PHP_INI_ ]; then
		php_ini_extra+=("$key = ${!name}")
	else
		fpm_pool_extra+=("$key = ${!name}")
	fi
done

# =============================================================================
# PHP
# =============================================================================
is_true PHP_OPCACHE_VALIDATE_TIMESTAMPS && validate=1 || validate=0

{
	echo "; Generated by apply-parameters.sh on every start. Do not edit:"
	echo "; set the environment variables, or add a file to $DROPIN_DIR/php/."
	echo "display_errors = $PHP_DISPLAY_ERRORS"
	echo "error_reporting = $PHP_ERROR_REPORTING"
	echo "upload_max_filesize = $PHP_UPLOAD_MAX_FILESIZE"
	echo "post_max_size = $PHP_POST_MAX_SIZE"
	echo "memory_limit = $PHP_MEMORY_LIMIT"
	echo "max_execution_time = $PHP_MAX_EXECUTION_TIME"
	echo "max_input_time = $PHP_MAX_INPUT_TIME"
	echo "max_input_vars = $PHP_MAX_INPUT_VARS"
	echo "date.timezone = \"$PHP_DATE_TIMEZONE\""
	# With 0, PHP never stats cached files again: faster, but an edit to
	# config_inc.php on the volume needs a restart to take effect.
	echo "opcache.validate_timestamps = $validate"
	if (( ${#php_ini_extra[@]} )); then
		echo
		echo "; From PHP_INI_* variables"
		printf '%s\n' "${php_ini_extra[@]}"
	fi
} > "$PHP_RUNTIME"

# =============================================================================
# PHP-FPM. A second [www] section in a later file overrides the directives of
# the distribution's www.conf, so that file stays untouched.
# =============================================================================
{
	echo "; Generated by apply-parameters.sh on every start. Do not edit:"
	echo "; set the environment variables, or add a file to $DROPIN_DIR/php-fpm/."
	echo "[www]"
	echo "pm = $PHP_FPM_PM"
	echo "pm.max_children = $PHP_FPM_MAX_CHILDREN"
	echo "pm.max_requests = $PHP_FPM_MAX_REQUESTS"
	case "$PHP_FPM_PM" in
		dynamic)
			echo "pm.start_servers = $PHP_FPM_START_SERVERS"
			echo "pm.min_spare_servers = $PHP_FPM_MIN_SPARE_SERVERS"
			echo "pm.max_spare_servers = $PHP_FPM_MAX_SPARE_SERVERS"
			;;
		ondemand)
			echo "pm.process_idle_timeout = $PHP_FPM_PROCESS_IDLE_TIMEOUT"
			;;
	esac
	# Wall-clock backstop: max_execution_time only counts time spent in PHP
	# itself, so a request stuck on the database or a socket was never killed
	# and the pool ran out of workers.
	echo "request_terminate_timeout = $PHP_FPM_REQUEST_TERMINATE_TIMEOUT"
	if (( ${#fpm_pool_extra[@]} )); then
		echo
		echo "; From PHP_FPM_POOL_* variables"
		printf '%s\n' "${fpm_pool_extra[@]}"
	fi
} > "$FPM_RUNTIME"

# =============================================================================
# TLS. The image no longer carries a certificate: one generated at build time
# put the same private key in every copy of a public image. Either the user
# supplies one, or a self-signed pair is generated once per container.
# =============================================================================
if is_true HTTPD_ENABLE_HTTPS; then
	if [ -n "$HTTPD_TLS_CERT_FILE" ]; then
		tls_cert=$HTTPD_TLS_CERT_FILE
		tls_key=$HTTPD_TLS_KEY_FILE
	else
		tls_cert=$TLS_DIR/selfsigned.crt
		tls_key=$TLS_DIR/selfsigned.key
		if [ ! -s "$tls_cert" ] || [ ! -s "$tls_key" ]; then
			cn=${HTTPD_SERVER_NAME%%:*}
			log "Generating a self-signed certificate for $cn"
			( umask 077
			  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
				-subj "/CN=$cn" -addext "subjectAltName=DNS:$cn" \
				-addext "basicConstraints=critical,CA:FALSE" \
				-addext "extendedKeyUsage=serverAuth" \
				-keyout "$tls_key" -out "$tls_cert" 2>/dev/null ) \
				|| die "could not generate a self-signed certificate"
		fi
	fi
fi

# =============================================================================
# Apache
# =============================================================================
# Loopback only, not `Require local`: that also accepts any connection whose
# client and server addresses match, which is every connection from the host
# under rootless podman's pasta networking.
status_require() {
	case "$HTTPD_STATUS_ALLOW" in
		local) echo "Require ip 127.0.0.1 ::1" ;;
		all)   echo "Require all granted" ;;
		none)  echo "Require all denied" ;;
		*)     echo "Require ip 127.0.0.1 ::1 ${HTTPD_STATUS_ALLOW//,/ }" ;;
	esac
}

{
	echo "# Generated by apply-parameters.sh on every start. Do not edit:"
	echo "# set the environment variables, or add a file to $DROPIN_DIR/httpd/."
	echo
	echo "ServerName $HTTPD_SERVER_NAME"
	# Also the timeout for the request to PHP-FPM (ProxyTimeout defaults to it).
	echo "Timeout $HTTPD_REQUEST_TIMEOUT"
	echo "LogLevel $HTTPD_LOG_LEVEL"
	echo
	# MantisBT reads its config folder from the environment of the PHP request.
	echo "SetEnv MANTIS_CONFIG_FOLDER $MANTIS_CONFIG_FOLDER"

	# MantisBT stays at /var/www/html/mantis on disk whatever the URL, so
	# mantis.conf, the scripts and `podman exec` paths never change.
	echo
	echo "# MantisBT URL (MANTIS_CONTEXT_PATH=${context:-/})."
	echo "Alias /healthz.php /var/www/html/healthz.php"
	if [ -z "$context" ]; then
		echo "DocumentRoot /var/www/html/mantis"
	else
		echo "DocumentRoot /var/www/empty"
		echo "Alias $context /var/www/html/mantis"
		# 302, not 301: browsers cache a 301 for good, and the context can change.
		echo "RedirectMatch 302 ^/\$ $context/"
	fi

	if [ -n "$HTTPD_TRUSTED_PROXIES" ]; then
		echo
		echo "# Take the client address from the proxy's header. The access log"
		echo "# uses %a, so it shows the real client rather than the proxy."
		echo "# MantisBT honours X-Forwarded-Proto by itself."
		echo "RemoteIPHeader $HTTPD_REMOTEIP_HEADER"
		echo "RemoteIPInternalProxy ${HTTPD_TRUSTED_PROXIES//,/ }"
	fi

	echo
	echo "# Status pages. They list client addresses and the URLs being"
	echo "# requested, so they are only open as far as HTTPD_STATUS_ALLOW says."
	echo "<Location \"/server-status\">"
	echo "    SetHandler server-status"
	status_require | sed 's/^/    /'
	echo "</Location>"
	echo "<Location \"/php-status\">"
	echo "    ProxyPass unix:/run/php-fpm/www.sock|fcgi://localhost/fpm-status"
	status_require | sed 's/^/    /'
	echo "</Location>"

	if is_true HTTPD_ENABLE_HTTPS; then
		echo
		echo "Define MANTIS_TLS_CERT $tls_cert"
		echo "Define MANTIS_TLS_KEY $tls_key"
		echo "Include /etc/httpd/mantis-ssl.conf"
	fi
} > "$HTTPD_RUNTIME"

# =============================================================================
# OpenID Connect. Apache (mod_auth_openidc) speaks the protocol and protects one
# URL, the OidcAuth plugin's login page; the plugin turns REMOTE_USER into a
# MantisBT session. See README-authentication.md for the design.
# =============================================================================
rm -f "$OIDC_RUNTIME"
if [ -n "$MANTIS_OIDC_ISSUER" ]; then
	# The client secret and passphrase are in this file: owner-only.
	( umask 077
	{
		echo "# Generated by apply-parameters.sh on every start from MANTIS_OIDC_*. Do not edit."
		echo "# Holds the client secret: readable by the apache user only."
		echo
		# Loaded here rather than from conf.modules.d, so the module is not
		# in the server at all while OpenID Connect is off.
		echo "LoadModule auth_openidc_module modules/mod_auth_openidc.so"
		echo
		echo "OIDCProviderMetadataURL \"${MANTIS_OIDC_ISSUER%/}/.well-known/openid-configuration\""
		echo "OIDCClientID \"$MANTIS_OIDC_CLIENT_ID\""
		echo "OIDCClientSecret \"$MANTIS_OIDC_CLIENT_SECRET\""
		echo "OIDCScope \"$MANTIS_OIDC_SCOPES\""
		echo "OIDCPKCEMethod S256"
		# Relative: mod_auth_openidc completes it from the request, which
		# keeps one configuration valid for every hostname MantisBT answers on.
		echo "OIDCRedirectURI $context/oidc/callback"
		echo "OIDCCryptoPassphrase \"$MANTIS_OIDC_CRYPTO_PASSPHRASE\""
		echo "OIDCRemoteUserClaim $MANTIS_OIDC_USERNAME_CLAIM"
		# As server variables only: a request header of the same name can be
		# forged on any URL this module does not protect.
		echo "OIDCPassClaimsAs environment"
		# The session lives in encrypted cookies, not in this container, so a
		# login may finish on another replica. store_id_token: client-cookie
		# leaves the id_token out by default, and without it logout cannot
		# send id_token_hint, so the IdP asks "do you want to log out?".
		echo "OIDCSessionType client-cookie:store_id_token"
		# MantisBT keeps its own session after login. This one is only needed
		# again at logout, to end the identity provider's session; keep it for
		# a working day.
		echo "OIDCSessionInactivityTimeout 28800"
		echo "OIDCSessionMaxDuration 28800"
		if [ -n "$HTTPD_TRUSTED_PROXIES" ]; then
			# Behind a TLS-terminating proxy the redirect URI must be built
			# from the public scheme and host, not from this container's.
			echo "OIDCXForwardedHeaders X-Forwarded-Proto X-Forwarded-Host"
		fi
		echo
		echo "<Location \"$context/oidc/callback\">"
		echo "    AuthType openid-connect"
		echo "    Require valid-user"
		echo "</Location>"
		echo
		echo "# The OidcAuth plugin's login page. PHP checks AUTH_TYPE as well, so a"
		echo "# request that slips past this match is refused, not let in."
		echo "<Location \"$context/plugin.php\">"
		echo "    <If \"%{QUERY_STRING} =~ m#(^|&)page=OidcAuth(/|%2[Ff])login(&|\$)#\">"
		echo "        AuthType openid-connect"
		echo "        Require valid-user"
		echo "    </If>"
		echo "</Location>"
	} > "$OIDC_RUNTIME" )
fi

{
	echo "<?php"
	echo "# Generated by apply-parameters.sh on every start from MANTIS_OIDC_*. Do not edit."
	echo "# Loaded at the end of config_inc.php."
	if [ -n "$MANTIS_OIDC_ISSUER" ]; then
		echo
		echo "# OpenID Connect login (plugins/OidcAuth)"
		echo "\$g_plugins_force_installed['OidcAuth'] = PLUGIN_PRIORITY_HIGH;"
		printf '$g_plugin_OidcAuth_local_users = array('
		sep=''
		for u in "${oidc_local_users[@]}"; do
			printf '%s %s' "$sep" "$(php_str "$u")"
			sep=','
		done
		echo ' );'
	else
		echo "# OpenID Connect is off: MANTIS_OIDC_ISSUER is not set."
	fi
} > "$MANTIS_RUNTIME_INC"
php -l "$MANTIS_RUNTIME_INC" >/dev/null || die "generated $MANTIS_RUNTIME_INC has a syntax error; this is a bug in apply-parameters.sh"

# =============================================================================
# Drop-in files: /mantis/conf.d/{php,php-fpm,httpd}/. Copied after the generated
# files and named to sort after them, so they win. Previous copies are removed
# first, so deleting a drop-in and restarting really removes it.
# =============================================================================
install_dropins() {
	local src=$1 dest=$2 ext=$3 f
	rm -f "$dest"/zzz-local-*
	[ -d "$src" ] || return 0
	for f in "$src"/*."$ext"; do
		[ -e "$f" ] || continue
		log "Applying drop-in $f"
		cp "$f" "$dest/zzz-local-$(basename "$f")"
	done
}
install_dropins "$DROPIN_DIR/php"     /etc/php.d         ini
install_dropins "$DROPIN_DIR/php-fpm" /etc/php-fpm.d     conf
install_dropins "$DROPIN_DIR/httpd"   /etc/httpd/conf.d  conf

log "PHP: upload ${PHP_UPLOAD_MAX_FILESIZE}, post ${PHP_POST_MAX_SIZE}, memory ${PHP_MEMORY_LIMIT}, timezone ${PHP_DATE_TIMEZONE}"
log "PHP-FPM: pm=${PHP_FPM_PM}, max_children=${PHP_FPM_MAX_CHILDREN}"
log "Apache: ServerName ${HTTPD_SERVER_NAME}, MantisBT at ${context:-/}, HTTPS $(is_true HTTPD_ENABLE_HTTPS && echo on || echo off), status pages: ${HTTPD_STATUS_ALLOW}"
if [ -n "$MANTIS_OIDC_ISSUER" ]; then
	log "OpenID Connect: issuer ${MANTIS_OIDC_ISSUER}, client ${MANTIS_OIDC_CLIENT_ID}, username from ${MANTIS_OIDC_USERNAME_CLAIM}, local login for: ${oidc_local_users[*]:-nobody}"
else
	log "OpenID Connect: off"
fi
