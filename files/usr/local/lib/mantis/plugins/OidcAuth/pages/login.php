<?php
# OpenID Connect login page: plugin.php?page=OidcAuth/login
#
# Apache (mod_auth_openidc) protects this URL, so by the time PHP runs the
# user has authenticated with the identity provider, and Apache passes:
#
#   AUTH_TYPE=openid-connect
#   REMOTE_USER=<the MANTIS_OIDC_USERNAME_CLAIM claim>
#   OIDC_CLAIM_email, OIDC_CLAIM_name, ...
#
# These are server variables, which a client cannot set; request headers would
# arrive as HTTP_*. The claims are passed as environment only (no headers).
#
# The user is looked up by username, created on first login, and has email
# and real name refreshed from the identity provider on every login.

require_api( 'authentication_api.php' );
require_api( 'config_api.php' );
require_api( 'email_api.php' );
require_api( 'gpc_api.php' );
require_api( 'helper_api.php' );
require_api( 'layout_api.php' );
require_api( 'print_api.php' );
require_api( 'string_api.php' );
require_api( 'user_api.php' );

$f_return = string_sanitize_url( gpc_get_string( 'return', '' ) );

/**
 * Show why the login failed and stop. Never redirects back into the login
 * flow, which would loop with the identity provider.
 *
 * @param string $p_message Already formatted, not yet escaped.
 * @param string $p_log     What goes to the PHP error log.
 */
function oidc_login_fail( $p_message, $p_log ) {
	error_log( 'OidcAuth: ' . $p_log );
	http_response_code( 403 );

	layout_login_page_begin( plugin_lang_get( 'error_title' ) );
	echo '<div class="col-md-offset-3 col-md-6 col-sm-10 col-sm-offset-1">';
	echo '<div class="login-container"><div class="space-12 hidden-480"></div>';
	layout_login_page_logo();
	echo '<div class="space-24 hidden-480"></div>';
	echo '<div class="alert alert-danger"><p>' . string_html_specialchars( $p_message ) . '</p></div>';
	echo '<p class="center">';
	echo '<a href="' . string_attribute( plugin_page( 'login' ) ) . '">' . plugin_lang_get( 'try_again' ) . '</a>';
	echo ' &middot; <a href="' . string_attribute( helper_mantis_url( OidcAuthPlugin::logout_url() ) ) . '">' . plugin_lang_get( 'sso_logout' ) . '</a>';
	echo ' &middot; <a href="' . string_attribute( helper_mantis_url( 'login_page.php?local=1' ) ) . '">' . plugin_lang_get( 'local_login' ) . '</a>';
	echo '</p></div></div>';
	layout_login_page_end();
	exit;
}

/**
 * A claim from mod_auth_openidc, as valid UTF-8.
 *
 * Apache is configured with "OIDCPassClaimsAs environment none", so values
 * arrive as the IdP sent them, in UTF-8. Should they ever arrive Latin-1
 * encoded (the module's default), they are converted here: written as they
 * are, MariaDB rejects them, and MantisBT's database errors halt the page
 * (APPLICATION ERROR #401) rather than throw, so a try/catch cannot help.
 *
 * @param string       $p_name       Claim name, as in OIDC_CLAIM_<name>.
 * @param integer|null $p_max_length Characters the database column holds,
 *                                   for values that may be shortened.
 * @return string Trimmed, possibly empty.
 */
function oidc_claim( $p_name, $p_max_length = null ) {
	$t_value = trim( $_SERVER['OIDC_CLAIM_' . $p_name] ?? '' );
	if( !mb_check_encoding( $t_value, 'UTF-8' ) ) {
		error_log( "OidcAuth: claim '$p_name' is not UTF-8; converted from Latin-1."
			. ' Is OIDCPassClaimsAs missing its "none" encoding?' );
		$t_value = mb_convert_encoding( $t_value, 'UTF-8', 'ISO-8859-1' );
	}
	return $p_max_length === null ? $t_value : mb_substr( $t_value, 0, $p_max_length, 'UTF-8' );
}

# --- Identity from Apache -----------------------------------------------------
if( ( $_SERVER['AUTH_TYPE'] ?? '' ) !== 'openid-connect' || is_blank( $_SERVER['REMOTE_USER'] ?? '' ) ) {
	oidc_login_fail( plugin_lang_get( 'error_not_protected' ),
		'login page reached without mod_auth_openidc (AUTH_TYPE=' . ( $_SERVER['AUTH_TYPE'] ?? '' ) . ')' );
}

$t_username = trim( $_SERVER['REMOTE_USER'] );
# Never shortened: a cut email is someone else's address. MantisBT validates it.
$t_email = oidc_claim( 'email' );
$t_realname = oidc_claim( 'name', DB_FIELD_SIZE_REALNAME );

if( !user_is_name_valid( $t_username ) ) {
	oidc_login_fail( sprintf( plugin_lang_get( 'error_invalid_username' ), $t_username ),
		"invalid username '$t_username'" );
}

# A break-glass account must not be reachable through the identity provider:
# anyone able to register that name there would become a MantisBT administrator.
if( OidcAuthPlugin::is_local_user( $t_username ) ) {
	oidc_login_fail( sprintf( plugin_lang_get( 'error_local_account' ), $t_username ),
		"refused '$t_username': listed in MANTIS_OIDC_LOCAL_USERS" );
}

# --- Find or create the MantisBT account --------------------------------------
$t_user_id = user_get_id_by_name( $t_username );

if( $t_user_id === false ) {
	# Accounts are matched by username only, never by email: linking on an
	# email address the identity provider may not have verified would let one
	# person take over another's account.
	if( !is_blank( $t_email ) && config_get_global( 'email_ensure_unique' ) && !user_is_email_unique( $t_email ) ) {
		oidc_login_fail( sprintf( plugin_lang_get( 'error_email_in_use' ), $t_email, $t_username ),
			"cannot create '$t_username': email '$t_email' belongs to another account" );
	}

	# user_create() mails new accounts a link to set a password, which means
	# nothing here: this account has no usable password.
	config_set_global( 'send_reset_password', OFF );
	try {
		user_create( $t_username, auth_generate_random_password(), $t_email,
			null, false, true, $t_realname );
	} catch( Exception $e ) {
		oidc_login_fail( sprintf( plugin_lang_get( 'error_create_failed' ), $e->getMessage() ),
			"cannot create '$t_username': " . $e->getMessage() );
	}
	$t_user_id = user_get_id_by_name( $t_username );
	error_log( "OidcAuth: created account '$t_username' (id $t_user_id)" );
} else {
	if( user_is_anonymous( $t_user_id ) ) {
		oidc_login_fail( sprintf( plugin_lang_get( 'error_anonymous' ), $t_username ),
			"refused '$t_username': anonymous account" );
	}

	# The identity provider is the source of truth for these two fields. A
	# change that MantisBT would reject (an email used by another account) is
	# logged and skipped rather than blocking the login.
	if( !is_blank( $t_email ) && strcasecmp( $t_email, user_get_email( $t_user_id ) ) != 0 ) {
		try {
			user_set_email( $t_user_id, $t_email );
		} catch( Exception $e ) {
			error_log( "OidcAuth: kept the email of '$t_username': " . $e->getMessage() );
		}
	}
	if( !is_blank( $t_realname ) && $t_realname !== user_get_realname( $t_user_id ) ) {
		try {
			user_set_realname( $t_user_id, $t_realname );
		} catch( Exception $e ) {
			error_log( "OidcAuth: kept the real name of '$t_username': " . $e->getMessage() );
		}
	}
}

# --- Log in -------------------------------------------------------------------
if( !auth_login_user( $t_user_id ) ) {
	oidc_login_fail( sprintf( plugin_lang_get( 'error_disabled' ), $t_username ),
		"refused '$t_username': account disabled" );
}

$t_return = is_blank( $f_return ) ? config_get_global( 'default_home_page' ) : $f_return;
print_header_redirect( helper_url_combine( 'login_cookie_test.php', array( 'return' => $t_return ) ) );
