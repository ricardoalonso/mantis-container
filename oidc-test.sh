#!/bin/bash
# End-to-end test of OpenID Connect login against a real identity provider:
# drives the browser flow with curl (redirects, the IdP's login form, cookies)
# instead of trusting that the configuration looks right.
#
#   OIDC_CLIENT_SECRET=... OIDC_TEST_PASSWORD=... OIDC_LOCAL_TEST_PASSWORD=... ./oidc-test.sh
#
# Needs, in the identity provider (README-authentication.md has the Keycloak
# steps):
#   - a confidential client OIDC_CLIENT_ID with redirect URI
#     http://localhost:$PORT/oidc/callback and post-logout redirect URI
#     http://localhost:$PORT/login_page.php
#   - user OIDC_TEST_USER, with an email address and a name
#   - user OIDC_LOCAL_TEST_USER, used to prove that a name listed in
#     MANTIS_OIDC_LOCAL_USERS is refused through single sign-on
#
# The login form is parsed as Keycloak renders it (form id kc-form-login).
#
# Checks, in order:
#   1. an anonymous visit is sent to the IdP, with PKCE and the right client
#   2. logging in at the IdP creates the MantisBT account and logs it in
#   3. the account has the IdP's email and name, and the default access level
#   4. SSO accounts cannot use or change a local password
#   5. a name in MANTIS_OIDC_LOCAL_USERS is refused through SSO
#   6. the break-glass administrator still logs in with the local form
#   7. the login page cannot be reached without Apache's authentication
#   8. REST and the liveness probe are not affected
#   9. logout ends the IdP session too
#  10. a second login reuses the account
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

REGISTRY=${REGISTRY:-quay.io/ricardoalonsos/mantis}
VERSION=${1:-$(sed -n 's/^ARG MANTIS_VERSION=\(.*\)$/\1/p' Containerfile)}
IMAGE="${REGISTRY}:${VERSION}"
POD=mantis-oidc-test
PORT=${PORT:-18090}
BASE="http://localhost:${PORT}"

OIDC_ISSUER=${OIDC_ISSUER:-http://localhost:8081/realms/mantis}
OIDC_CLIENT_ID=${OIDC_CLIENT_ID:-mantis}
OIDC_TEST_USER=${OIDC_TEST_USER:-mantis-alice}
OIDC_TEST_EMAIL=${OIDC_TEST_EMAIL:-alice@example.test}
OIDC_TEST_NAME=${OIDC_TEST_NAME:-Alice Tester}
OIDC_LOCAL_TEST_USER=${OIDC_LOCAL_TEST_USER:-mantis-breakglass}
: "${OIDC_CLIENT_SECRET:?set OIDC_CLIENT_SECRET}"
: "${OIDC_TEST_PASSWORD:?set OIDC_TEST_PASSWORD}"
: "${OIDC_LOCAL_TEST_PASSWORD:?set OIDC_LOCAL_TEST_PASSWORD}"

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; podman logs --tail 15 "$POD-app" 2>&1 | sed 's/^/       /'; exit 1; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

WORK=$(mktemp -d)
cleanup() { podman pod rm -f "$POD" >/dev/null 2>&1 || true; }
# KEEP=1 leaves the pod and the cookie jars behind for debugging.
if [ "${KEEP:-0}" = 1 ]; then
	trap 'echo "kept: pod $POD, work dir $WORK"' EXIT
else
	trap 'cleanup; rm -rf "$WORK"' EXIT
fi

podman image exists "$IMAGE" || fail "$IMAGE is not built. Run ./build.sh $VERSION"

# The browser and the container must reach the IdP under the same URL, or the
# issuer in the tokens does not match the one MantisBT expects. For an IdP on
# this host's localhost, forward the container's localhost:<port> to it.
idp_hostport=${OIDC_ISSUER#*://}; idp_hostport=${idp_hostport%%/*}
network=()
case "$idp_hostport" in
	localhost:*|127.0.0.1:*) network=(--network "pasta:-T,${idp_hostport##*:}") ;;
esac

# Secret by file, to exercise MANTIS_OIDC_CLIENT_SECRET_FILE.
printf '%s' "$OIDC_CLIENT_SECRET" > "$WORK/client-secret"
chmod a+r "$WORK/client-secret"

# curl with a cookie jar per "browser". -s silent, no -L: every hop is checked.
browser() { local jar=$1; shift; curl -s -b "$WORK/$jar.jar" -c "$WORK/$jar.jar" "$@"; }
# location <jar> <url>: the redirect target, or nothing.
location() { browser "$1" -o /dev/null -w '%{redirect_url}' "$2"; }
# follow <jar> <url>: follows redirects, prints "<code> <final url>" and keeps the body.
follow() { browser "$1" -L -o "$WORK/body" -w '%{http_code} %{url_effective}' "$2"; }

# idp_login <jar> <user> <password>: from a fresh visit to MantisBT through
# the IdP's form, leaving the final MantisBT page in $WORK/body.
idp_login() {
	local jar=$1 user=$2 password=$3 action
	follow "$jar" "$BASE/" >/dev/null
	action=$(python3 -c '
import html, re, sys
m = re.search(r"<form[^>]*id=\"kc-form-login\"[^>]*action=\"([^\"]+)\"", open(sys.argv[1]).read())
print(html.unescape(m.group(1)) if m else "")' "$WORK/body")
	[ -n "$action" ] || fail "no IdP login form after visiting MantisBT"
	browser "$jar" -L -o "$WORK/body" -w '%{http_code} %{url_effective}' \
		--data-urlencode "username=$user" --data-urlencode "password=$password" \
		--data-urlencode credentialId= "$action"
}

# token: the anti-CSRF token of the MantisBT login form in $WORK/body.
token() { python3 -c 'import re,sys; m=re.search(r"name=\"login_token\" value=\"([^\"]+)\"", open(sys.argv[1]).read()); print(m.group(1) if m else "")' "$WORK/body"; }

db() { podman exec "$POD-db" mariadb -uroot -proot -N -B bugtracker -e "$1"; }

# -----------------------------------------------------------------------------
step "0. MantisBT with OpenID Connect against $OIDC_ISSUER"
cleanup
podman pod create --name "$POD" -p "${PORT}:8080" "${network[@]}" >/dev/null
podman run -d --pod "$POD" --name "$POD-db" \
	-e MARIADB_ROOT_PASSWORD=root -e MARIADB_DATABASE=bugtracker \
	docker.io/library/mariadb:11 >/dev/null
for _ in $(seq 1 60); do
	podman exec "$POD-db" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 && break
	sleep 1
done
podman run -d --pod "$POD" --name "$POD-app" \
	-e MANTIS_ADMINISTRATION_ENABLED=true \
	-e MANTIS_DB_HOST=127.0.0.1 -e MANTIS_DB_USER=root -e MANTIS_DB_PASSWORD=root \
	-e MANTIS_OIDC_ISSUER="$OIDC_ISSUER" \
	-e MANTIS_OIDC_CLIENT_ID="$OIDC_CLIENT_ID" \
	-e MANTIS_OIDC_CLIENT_SECRET_FILE=/run/oidc/client-secret \
	-e MANTIS_OIDC_LOCAL_USERS="administrator, $OIDC_LOCAL_TEST_USER" \
	-v "$WORK/client-secret:/run/oidc/client-secret:ro,Z" \
	"$IMAGE" >/dev/null
for _ in $(seq 1 60); do
	curl -fsS -o /dev/null "$BASE/healthz.php" 2>/dev/null && break
	sleep 1
done
curl -fsS -o /dev/null "$BASE/healthz.php" || fail "container did not start"
install=$(curl -s --max-time 180 "$BASE/admin/install.php" \
	--data-urlencode install=2 --data-urlencode db_type=mysqli \
	--data-urlencode hostname=127.0.0.1 --data-urlencode database_name=bugtracker \
	--data-urlencode db_username=root --data-urlencode db_password=root \
	--data-urlencode admin_username=root --data-urlencode admin_password=root \
	--data-urlencode db_table_prefix=mantis --data-urlencode db_table_plugin_prefix=plugin \
	--data-urlencode db_table_suffix=_table --data-urlencode timezone=UTC || true)
printf '%s' "$install" | grep -q 'installed successfully' || fail "MantisBT installer did not complete"
pass "MantisBT installed, OIDC configured from MANTIS_OIDC_* (secret from a file)"

# -----------------------------------------------------------------------------
step "1. An anonymous visit goes to the identity provider"
to=$(location anon "$BASE/login_page.php")
case "$to" in
	"$BASE/plugin.php?page=OidcAuth/login"*) ;;
	*) fail "login_page.php redirected to '$to', not to the OIDC login page" ;;
esac
pass "login_page.php -> OidcAuth login page"
to=$(location anon "$to")
case "$to" in
	"$OIDC_ISSUER/protocol/openid-connect/auth?"*|"$OIDC_ISSUER"*"/auth?"*) ;;
	*) fail "the OIDC login page redirected to '$to', not to the IdP" ;;
esac
for want in "client_id=$OIDC_CLIENT_ID" "code_challenge_method=S256" "response_type=code" \
            "redirect_uri=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$BASE/oidc/callback")"; do
	[[ $to == *"$want"* ]] || fail "authorization request lacks $want: $to"
done
pass "authorization request: code flow, PKCE S256, client $OIDC_CLIENT_ID, redirect $BASE/oidc/callback"

# -----------------------------------------------------------------------------
step "2. Logging in at the identity provider logs in to MantisBT"
result=$(idp_login alice "$OIDC_TEST_USER" "$OIDC_TEST_PASSWORD")
[[ $result == "200 $BASE/"* ]] || fail "login ended at '$result'"
grep -q "$OIDC_TEST_USER" "$WORK/body" || fail "MantisBT page after login does not show $OIDC_TEST_USER"
grep -qi 'logout_page.php' "$WORK/body" || fail "not logged in after the IdP login"
pass "logged in as $OIDC_TEST_USER (landed on ${result#* })"

# -----------------------------------------------------------------------------
step "3. The account comes from the IdP's claims"
row=$(db "SELECT email, realname, access_level, enabled FROM mantis_user_table WHERE username='$OIDC_TEST_USER'")
[ -n "$row" ] || fail "no MantisBT account $OIDC_TEST_USER"
IFS=$'\t' read -r email realname access enabled <<<"$row"
[ "$email" = "$OIDC_TEST_EMAIL" ] || fail "email is '$email', expected $OIDC_TEST_EMAIL"
[ "$realname" = "$OIDC_TEST_NAME" ] || fail "real name is '$realname', expected $OIDC_TEST_NAME"
[ "$access" = "25" ] || fail "access level is $access, expected 25 (REPORTER, the MantisBT default)"
[ "$enabled" = "1" ] || fail "account is not enabled"
pass "account created: email $email, real name '$realname', access level REPORTER"
# Not piped into grep -q: with pipefail, grep exiting early fails podman logs.
logs=$(podman logs "$POD-app" 2>&1)
grep -q "OidcAuth: created account '$OIDC_TEST_USER'" <<<"$logs" || fail "account creation is not logged"
pass "creation is logged"

# -----------------------------------------------------------------------------
step "4. SSO accounts have no local password"
follow alice "$BASE/account_page.php" >/dev/null
grep -q 'name="password"' "$WORK/body" && fail "account page offers a password change"
grep -q "managed by your organisation" "$WORK/body" || fail "account page does not say the password is managed elsewhere"
pass "account page: no password fields, says the IdP manages it"
follow fresh "$BASE/login_page.php?local=1" >/dev/null
to=$(browser fresh -o /dev/null -w '%{redirect_url}' "$BASE/login_password_page.php" \
	--data-urlencode "username=$OIDC_TEST_USER" --data-urlencode "login_token=$(token)")
[[ $to == "$BASE/plugin.php?page=OidcAuth/login"* ]] || fail "the local form for an SSO account went to '$to'"
pass "typing an SSO username in the local form leads to the IdP, not to a password prompt"

# -----------------------------------------------------------------------------
step "5. A break-glass name is refused through SSO"
result=$(idp_login bg "$OIDC_LOCAL_TEST_USER" "$OIDC_LOCAL_TEST_PASSWORD")
[[ $result == "403 $BASE/plugin.php?page=OidcAuth/login"* ]] || fail "SSO as $OIDC_LOCAL_TEST_USER ended at '$result'"
grep -q "reserved for local login" "$WORK/body" || fail "no explanation on the refusal page"
[ -z "$(db "SELECT id FROM mantis_user_table WHERE username='$OIDC_LOCAL_TEST_USER'")" ] \
	|| fail "an account was created for $OIDC_LOCAL_TEST_USER"
pass "$OIDC_LOCAL_TEST_USER (in MANTIS_OIDC_LOCAL_USERS): 403 with an explanation, no account created"

# -----------------------------------------------------------------------------
step "6. The break-glass administrator logs in locally"
code=$(follow admin "$BASE/login_page.php?local=1"); [[ $code == "200 "* ]] || fail "login_page.php?local=1 returned $code"
grep -q 'name="username"' "$WORK/body" || fail "login_page.php?local=1 shows no username form"
browser admin -L -o "$WORK/body" "$BASE/login_password_page.php" \
	--data-urlencode username=administrator --data-urlencode "login_token=$(token)"
grep -q 'name="password"' "$WORK/body" || fail "no password form for administrator"
result=$(browser admin -L -o "$WORK/body" -w '%{http_code} %{url_effective}' "$BASE/login.php" \
	--data-urlencode username=administrator --data-urlencode password=root \
	--data-urlencode "login_token=$(token)")
grep -qi 'logout_page.php' "$WORK/body" || fail "administrator did not get in with the local password (ended at $result)"
pass "administrator / local password works (MANTIS_OIDC_LOCAL_USERS)"
browser badpw -L -o "$WORK/body" "$BASE/login_page.php?local=1"
browser badpw -L -o "$WORK/body" "$BASE/login_password_page.php" \
	--data-urlencode username=administrator --data-urlencode "login_token=$(token)"
result=$(browser badpw -L -o "$WORK/body" -w '%{url_effective}' "$BASE/login.php" \
	--data-urlencode username=administrator --data-urlencode password=wrong \
	--data-urlencode "login_token=$(token)")
[[ $result == "$BASE/login_page.php?"*error=1* ]] || fail "a wrong local password ended at '$result'"
grep -q 'name="username"' "$WORK/body" || fail "a wrong local password did not return to the local form"
pass "a wrong password returns to the local form, not to the IdP"

# -----------------------------------------------------------------------------
step "7. The login page cannot be reached around Apache"
# %4F is "O": PHP decodes it to OidcAuth/login, Apache's match sees it encoded.
code=$(curl -s -o "$WORK/body" -w '%{http_code}' \
	-H "Remote-User: $OIDC_TEST_USER" -H "OIDC_CLAIM_email: evil@example.test" \
	"$BASE/plugin.php?page=%4FidcAuth/login")
[ "$code" = "403" ] && grep -q "did not authenticate the request" "$WORK/body" \
	|| fail "unauthenticated request to the login page returned $code"
pass "encoded page name + forged Remote-User header: 403, refused by PHP"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/oidc/callback?code=x&state=y")
case "$code" in 4*|5*) ;; *) fail "forged callback returned $code" ;; esac
pass "forged callback rejected by mod_auth_openidc (HTTP $code)"

# -----------------------------------------------------------------------------
step "8. REST and probes are untouched"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/rest/users/me")
[ "$code" = "401" ] || fail "REST without a token returned $code, expected 401"
pass "REST without a token: 401, no IdP redirect"
podman exec "$POD-app" healthcheck.sh || fail "healthcheck fails with OIDC enabled"
pass "healthcheck passes"

# -----------------------------------------------------------------------------
step "9. Logout ends the IdP session"
to=$(location alice "$BASE/logout_page.php")
[[ $to == "$BASE/oidc/callback?logout="* ]] || fail "logout went to '$to'"
to=$(location alice "$to")
[[ $to == "$OIDC_ISSUER/protocol/openid-connect/logout?"* ]] || fail "mod_auth_openidc logout went to '$to', not to the IdP"
[[ $to == *id_token_hint=* ]] || fail "IdP logout without id_token_hint (would ask for confirmation): $to"
pass "MantisBT -> mod_auth_openidc -> IdP end_session with id_token_hint"
result=$(follow alice "$to")
grep -q 'id="kc-form-login"' "$WORK/body" || fail "after logout the IdP did not ask for credentials again (ended at $result)"
pass "back at MantisBT, the IdP asks for credentials again"
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$WORK/alice.jar" "$BASE/my_view_page.php")
[ "$code" = "302" ] || fail "MantisBT page after logout returned $code, expected a redirect to log in"
pass "the MantisBT session is gone"

# -----------------------------------------------------------------------------
step "10. A second login reuses the account"
rm -f "$WORK/alice.jar"
result=$(idp_login alice "$OIDC_TEST_USER" "$OIDC_TEST_PASSWORD")
grep -qi 'logout_page.php' "$WORK/body" || fail "second login failed (ended at $result)"
[ "$(db "SELECT COUNT(*) FROM mantis_user_table WHERE username='$OIDC_TEST_USER'")" = "1" ] \
	|| fail "second login created another account"
[ "$(db "SELECT login_count FROM mantis_user_table WHERE username='$OIDC_TEST_USER'")" -ge 2 ] \
	|| fail "login count did not increase"
pass "same account, login count increased"

printf '\n\033[32mAll OpenID Connect tests passed for %s against %s\033[0m\n' "$IMAGE" "$OIDC_ISSUER"
