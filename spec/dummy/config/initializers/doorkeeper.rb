Doorkeeper.configure do
  orm :active_record

  resource_owner_authenticator do
    if session[:user_id] && (user = RailsMcp::User.find_by(id: session[:user_id]))
      user
    else
      redirect_to "/sign_in"
    end
  end

  use_refresh_token

  # Store only a hash of access and refresh tokens, so a database leak doesn't
  # hand out live bearer tokens. `fallback: :plain` keeps tokens issued before
  # this change working until they expire or are refreshed. Hashed tokens can't
  # be returned again, so access tokens aren't reused (reuse_access_token).
  hash_token_secrets fallback: :plain

  default_scopes  :read
  optional_scopes :write
  enforce_configured_scopes

  grant_flows %w[authorization_code refresh_token]
  pkce_code_challenge_methods %w[S256]
  force_pkce

  access_token_expires_in 8.hours

  force_ssl_in_redirect_uri { Rails.env.production? }

  base_controller "RailsMcp::OauthBaseController"
end
