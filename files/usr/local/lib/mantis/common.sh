# Shared helpers for the entrypoint scripts. Sourced, not executed.
#
# This file is also the single place the runtime defaults live. The Containerfile
# deliberately does not repeat them as ENV, so the two cannot drift apart, and
# README-usage.md documents them.

# MantisBT settings the container derives from MANTIS_OIDC_* on every start.
# Written by apply-parameters.sh, loaded by config_inc.php.
MANTIS_RUNTIME_INC=/etc/mantis/runtime_inc.php

# MantisBT's plugins/ is a symlink to PLUGINS_DIR (a volume), which
# install-plugins.sh fills on every start from BUNDLED_PLUGINS_DIR (the image's
# own plugins), MANTIS_PLUGINS (downloads) and whatever else you put there.
PLUGINS_DIR=/mantis/plugins
BUNDLED_PLUGINS_DIR=/usr/local/lib/mantis/bundled-plugins

log()  { printf '[entrypoint] %s\n' "$*"; }
warn() { printf '[entrypoint] WARNING: %s\n' "$*" >&2; }
die()  { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

#
# is_true <NAME>
#
# Parses a boolean variable. The previous entrypoint ran the value as a command
# (`if $VAR`), so "1" or "on" silently meant false and "yes" ran /usr/bin/yes
# and hung the container. An unrecognised value is an error, not a guess.
is_true() {
	local name=$1 value
	value=${!name:-}
	case "${value,,}" in
		true|yes|on|1)      return 0 ;;
		false|no|off|0|'')  return 1 ;;
		*) die "$name='$value' is not a boolean (use true/false, yes/no, on/off, 1/0)" ;;
	esac
}

# require_bool <NAME>: validates without using the result, so every error shows
# up before anything is written.
require_bool() { is_true "$1" || true; }

# require_int <NAME> [min]
require_int() {
	local name=$1 min=${2:-0} value
	value=${!name:-}
	[[ $value =~ ^[0-9]+$ ]] || die "$name='$value' is not a whole number"
	(( value >= min )) || die "$name=$value must be at least $min"
}

# require_size <NAME>: a PHP shorthand size such as 512K, 64M, 2G or a byte count.
require_size() {
	local name=$1 value
	value=${!name:-}
	[[ $value =~ ^[0-9]+[KkMmGg]?$ ]] \
		|| die "$name='$value' is not a size (examples: 4M, 512K, 1G; note 4MB is not valid)"
}

# size_to_bytes <size>: prints the size in bytes; -1 stays -1.
size_to_bytes() {
	local value=$1 number unit
	[ "$value" = "-1" ] && { echo -1; return; }
	number=${value%[KkMmGg]}
	unit=${value#"$number"}
	case "${unit,,}" in
		k) echo $(( number * 1024 )) ;;
		m) echo $(( number * 1024 * 1024 )) ;;
		g) echo $(( number * 1024 * 1024 * 1024 )) ;;
		*) echo "$number" ;;
	esac
}

# require_match <NAME> <regex> <description>
require_match() {
	local name=$1 regex=$2 what=$3 value
	value=${!name:-}
	[[ $value =~ $regex ]] || die "$name='$value' is not valid: expected $what"
}

# require_one_line <NAME>: nothing that ends up in a config file may contain a
# newline, or it could inject extra directives.
require_one_line() {
	local name=$1
	[[ ${!name:-} != *$'\n'* ]] || die "$name must not contain a newline"
}

#
# file_env <NAME>
#
# Lets any secret be supplied as NAME_FILE=/run/secrets/..., so passwords need
# not sit in the container's environment, where `inspect` shows them.
file_env() {
	local name=$1 file_name="${1}_FILE" file
	file=${!file_name:-}
	[ -n "$file" ] || return 0
	[ -z "${!name:-}" ] || die "set either $name or $file_name, not both"
	[ -r "$file" ] || die "$file_name=$file is not readable"
	# Strip the trailing newline most editors and `echo` leave behind.
	printf -v "$name" '%s' "$(<"$file")"
	export "${name?}"
}

# php_str <value>: a PHP single-quoted string literal.
php_str() {
	local s=$1
	s=${s//\\/\\\\}
	s=${s//\'/\\\'}
	printf "'%s'" "$s"
}

#
# context_path: MANTIS_CONTEXT_PATH normalised to "" for the root or "/name"
# otherwise -- no trailing slash, so "$(context_path)/admin/" is always right.
# Validated in apply-parameters.sh.
context_path() {
	local path=${MANTIS_CONTEXT_PATH#/}
	path=${path%/}
	echo "${path:+/$path}"
}

#
# Defaults. `:=` also replaces a variable that is set but empty, so `-e VAR=`
# means "use the default" rather than producing an invalid config.
#
set_defaults() {
	# MantisBT
	: "${MANTIS_CONFIG_FOLDER:=/mantis/config/}"
	: "${MANTIS_CONTEXT_PATH:=/}"
	: "${MANTIS_ADMINISTRATION_ENABLED:=false}"
	: "${MANTIS_DB_TYPE:=mysqli}"
	: "${MANTIS_DB_NAME:=bugtracker}"
	: "${MANTIS_FILE_UPLOAD_METHOD:=DISK}"
	: "${MANTIS_UPLOAD_FOLDER:=/mantis/attachments/}"
	: "${MANTIS_SMTP_PORT:=587}"
	: "${MANTIS_SMTP_CONNECTION_MODE:=tls}"
	: "${MANTIS_LDAP_UID_FIELD:=uid}"
	: "${MANTIS_LDAP_PROTOCOL_VERSION:=3}"
	: "${MANTIS_LDAP_USE_STARTTLS:=true}"
	: "${MANTIS_LDAP_FOLLOW_REFERRALS:=false}"

	# OpenID Connect: off unless MANTIS_OIDC_ISSUER is set
	: "${MANTIS_OIDC_ISSUER:=}"
	: "${MANTIS_OIDC_SCOPES:=openid email profile}"
	: "${MANTIS_OIDC_USERNAME_CLAIM:=preferred_username}"
	: "${MANTIS_OIDC_LOCAL_USERS:=administrator}"

	# PHP
	: "${PHP_UPLOAD_MAX_FILESIZE:=4M}"
	: "${PHP_POST_MAX_SIZE:=}"                       # derived below
	: "${PHP_MEMORY_LIMIT:=256M}"
	: "${PHP_DISPLAY_ERRORS:=Off}"
	: "${PHP_ERROR_REPORTING:=E_ALL & ~E_DEPRECATED}"
	: "${PHP_MAX_EXECUTION_TIME:=30}"
	: "${PHP_MAX_INPUT_TIME:=60}"
	: "${PHP_MAX_INPUT_VARS:=1000}"
	: "${PHP_DATE_TIMEZONE:=${TZ:-UTC}}"
	: "${PHP_OPCACHE_VALIDATE_TIMESTAMPS:=On}"

	# PHP-FPM
	: "${PHP_FPM_PM:=dynamic}"
	: "${PHP_FPM_MAX_CHILDREN:=20}"
	: "${PHP_FPM_MAX_REQUESTS:=500}"
	: "${PHP_FPM_PROCESS_IDLE_TIMEOUT:=10s}"
	: "${PHP_FPM_REQUEST_TERMINATE_TIMEOUT:=$PHP_MAX_EXECUTION_TIME}"

	# Apache
	: "${HTTPD_SERVER_NAME:=localhost}"
	: "${HTTPD_REQUEST_TIMEOUT:=60}"
	: "${HTTPD_LOG_LEVEL:=warn}"
	: "${HTTPD_TRUSTED_PROXIES:=}"
	: "${HTTPD_REMOTEIP_HEADER:=X-Forwarded-For}"
	: "${HTTPD_STATUS_ALLOW:=local}"
	: "${HTTPD_ENABLE_HTTPS:=true}"
	: "${HTTPD_TLS_CERT_FILE:=}"
	: "${HTTPD_TLS_KEY_FILE:=}"

	export MANTIS_CONFIG_FOLDER
}
