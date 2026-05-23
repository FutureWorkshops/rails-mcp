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

  default_scopes  :read
  optional_scopes :write
  enforce_configured_scopes

  grant_flows %w[authorization_code refresh_token]
  pkce_code_challenge_methods %w[S256]

  access_token_expires_in 8.hours
  reuse_access_token

  force_ssl_in_redirect_uri { Rails.env.production? }

  base_controller "RailsMcp::OauthBaseController"
end
