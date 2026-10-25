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

# --- Identity from Apache -----------------------------------------------------
if( ( $_SERVER['AUTH_TYPE'] ?? '' ) !== 'openid-connect' || is_blank( $_SERVER['REMOTE_USER'] ?? '' ) ) {
	oidc_login_fail( plugin_lang_get( 'error_not_protected' ),
		'login page reached without mod_auth_openidc (AUTH_TYPE=' . ( $_SERVER['AUTH_TYPE'] ?? '' ) . ')' );
}

$t_username = trim( $_SERVER['REMOTE_USER'] );
$t_email = trim( $_SERVER['OIDC_CLAIM_email'] ?? '' );
$t_realname = trim( $_SERVER['OIDC_CLAIM_name'] ?? '' );

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
		user_set_realname( $t_user_id, $t_realname );
	}
}

# --- Log in -------------------------------------------------------------------
if( !auth_login_user( $t_user_id ) ) {
	oidc_login_fail( sprintf( plugin_lang_get( 'error_disabled' ), $t_username ),
		"refused '$t_username': account disabled" );
}

$t_return = is_blank( $f_return ) ? config_get_global( 'default_home_page' ) : $f_return;
print_header_redirect( helper_url_combine( 'login_cookie_test.php', array( 'return' => $t_return ) ) );
