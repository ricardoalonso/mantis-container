<?php
# OpenID Connect login for MantisBT, shipped with the container image.
#
# The OpenID Connect protocol itself is handled by Apache (mod_auth_openidc),
# which protects exactly one URL: this plugin's login page. When a request
# reaches that page, Apache has already authenticated the user with the
# identity provider and passes the result as REMOTE_USER and OIDC_CLAIM_*.
# The plugin turns that into a MantisBT session, and uses the authentication
# API (EVENT_AUTH_USER_FLAGS) to send everyone but the break-glass accounts
# there instead of to the password form.
#
# Enabled and configured by the container from MANTIS_OIDC_* (see
# /etc/mantis/runtime_inc.php and README-authentication.md); it is never
# installed through Manage Plugins.

class OidcAuthPlugin extends MantisPlugin {
	/**
	 * The redirect URI mod_auth_openidc handles, relative to the MantisBT root.
	 * apply-parameters.sh protects the same path.
	 */
	const CALLBACK_PATH = 'oidc/callback';

	function register() {
		$this->name = plugin_lang_get( 'title' );
		$this->description = plugin_lang_get( 'description' );
		$this->page = '';

		$this->version = '1.0.0';
		$this->requires = array(
			'MantisCore' => '2.25.0',
		);

		$this->author = 'mantis-container';
		$this->url = 'https://github.com/ricardoalonso/mantis-container';
	}

	function config() {
		return array(
			# Accounts that keep the local password form and can never log in
			# through OpenID Connect. Compared case-insensitively.
			'local_users' => array( 'administrator' ),
		);
	}

	function hooks() {
		return array(
			'EVENT_AUTH_USER_FLAGS' => 'auth_user_flags',
			'EVENT_CORE_READY' => 'core_ready',
		);
	}

	/**
	 * Whether the username is one of the break-glass accounts.
	 *
	 * @param string $p_username A username.
	 * @return bool
	 */
	static function is_local_user( $p_username ) {
		if( is_blank( $p_username ) ) {
			return false;
		}
		$t_local_users = plugin_config_get( 'local_users', array(), true, null, null );
		foreach( (array)$t_local_users as $t_local_user ) {
			if( strcasecmp( trim( $t_local_user ), trim( $p_username ) ) == 0 ) {
				return true;
			}
		}
		return false;
	}

	/**
	 * URL (relative to the MantisBT root) that ends the mod_auth_openidc
	 * session and the identity provider's session, then returns to MantisBT.
	 *
	 * @return string
	 */
	static function logout_url() {
		return self::CALLBACK_PATH . '?logout='
			. rawurlencode( config_get_global( 'path' ) . 'login_page.php' );
	}

	/**
	 * Authentication flags for a user: OpenID Connect for everyone except the
	 * anonymous account and the break-glass accounts, which get MantisBT's
	 * defaults (null).
	 */
	function auth_user_flags( $p_event_name, $p_args ) {
		$t_user_id = $p_args['user_id'];
		$t_username = $p_args['username'];

		if( $t_user_id && user_is_anonymous( $t_user_id ) ) {
			return null;
		}
		if( self::is_local_user( $t_username ) ) {
			return null;
		}

		$t_flags = new AuthFlags();

		# No password login, no password changes: the identity provider owns
		# the credentials. This also refuses passwords on SOAP; REST and SOAP
		# clients use API tokens instead.
		$t_flags->setCanUseStandardLogin( false );
		$t_flags->setPasswordManagedExternallyMessage( plugin_lang_get( 'password_managed_elsewhere' ) );

		# Typing such a username in the local form leads to OpenID Connect.
		$t_flags->setCredentialsPage( plugin_page( 'login', true ) );
		$t_flags->setLogoutRedirectPage( self::logout_url() );

		# "Remember me" would outlive the identity provider's decision.
		$t_flags->setPermSessionEnabled( false );

		return $t_flags;
	}

	/**
	 * login_page.php normally asks for a username. Send the browser straight
	 * to OpenID Connect instead, unless the local form is wanted: ?local=1,
	 * or a failed local login coming back with error/username.
	 */
	function core_ready() {
		if( basename( $_SERVER['SCRIPT_NAME'] ?? '' ) !== 'login_page.php' ) {
			return;
		}
		if( gpc_get_bool( 'local' ) || gpc_get_bool( 'error' ) || gpc_isset( 'username' ) ) {
			return;
		}
		if( auth_is_user_authenticated() && !current_user_is_anonymous() ) {
			# login_page.php redirects authenticated users itself.
			return;
		}

		$t_return = string_sanitize_url( gpc_get_string( 'return', '' ) );
		$t_query = is_blank( $t_return ) ? array() : array( 'return' => $t_return );
		print_header_redirect( helper_url_combine( plugin_page( 'login', true ), $t_query ) );
	}
}
