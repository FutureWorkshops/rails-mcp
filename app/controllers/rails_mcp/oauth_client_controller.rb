module RailsMcp
  # Abstract base class for OAuth-client SSO controllers in MCP host apps.
  # Subclasses sign visitors in by doing an authorization-code round-trip
  # against an upstream OAuth provider (typically Cowork Hub), then upsert
  # a local RailsMcp::User keyed by the provider's stable `sub` claim and
  # mirror the user's current account onto a local RailsMcp::Account
  # keyed by a `cowork_account_id`-style column.
  #
  # Subclasses must override:
  #   - .authorize_url, .token_url, .userinfo_url
  #   - .client_id, .client_secret  (read from credentials)
  #   - .redirect_uri               (full URL of the subclass's #callback)
  #   - .scope                      (defaults to "openid")
  #   - .state_session_key          (defaults to :rails_mcp_oauth_client_state)
  #
  # The default routes layout is `/<provider>/connect` → #connect and
  # `/<provider>/callback` → #callback, but subclasses choose their own.
  #
  # The mirrored-account column defaults to `cowork_account_id`. Override
  # `mirror_account_column` if your IdP names accounts differently.
  class OauthClientController < ::ApplicationController
    # ---- Subclass hooks (defaults are Cowork Hub conventions) ------------

    def self.authorize_url      = raise NotImplementedError, "#{name}.authorize_url must be defined"
    def self.token_url          = raise NotImplementedError, "#{name}.token_url must be defined"
    def self.userinfo_url       = raise NotImplementedError, "#{name}.userinfo_url must be defined"
    def self.client_id          = raise NotImplementedError, "#{name}.client_id must be defined"
    def self.client_secret      = raise NotImplementedError, "#{name}.client_secret must be defined"
    def self.redirect_uri       = raise NotImplementedError, "#{name}.redirect_uri must be defined"
    def self.scope              = "openid"
    def self.state_session_key  = :rails_mcp_oauth_client_state
    def self.mirror_account_column = :cowork_account_id

    # ---- Actions ----------------------------------------------------------

    def connect
      state = SecureRandom.hex(16)
      session[self.class.state_session_key] = state

      query = {
        response_type: "code",
        client_id:     self.class.client_id,
        redirect_uri:  self.class.redirect_uri,
        scope:         self.class.scope,
        state:         state
      }.to_query

      redirect_to "#{self.class.authorize_url}?#{query}", allow_other_host: true
    end

    def callback
      if params[:state] != session.delete(self.class.state_session_key)
        return redirect_to root_path, alert: "Invalid SSO state. Please try again."
      end

      if params[:error].present?
        return redirect_to root_path, alert: "Sign-in failed: #{params[:error]}"
      end

      tokens   = exchange_code(params[:code])
      identity = fetch_userinfo(tokens.fetch(:access_token))
      user     = upsert_user(identity)

      return_to = session[:return_to]
      reset_session
      session[:user_id] = user.id

      redirect_to safe_return_to(return_to) || after_sign_in_path,
                  notice: "Signed in as #{user.email}."
    rescue StandardError => e
      Rails.logger.error("#{self.class.name} callback failed: #{e.class}: #{e.message}")
      redirect_to root_path, alert: "Sign-in failed: #{e.message}"
    end

    private

    # Where to land after a successful sign-in if no return_to was stashed.
    # Override in subclasses if /connections isn't the right default.
    def after_sign_in_path
      "/connections"
    end

    def safe_return_to(path)
      return nil if path.blank?
      return nil unless path.start_with?("/")
      return nil if path.start_with?("//")

      path
    end

    def exchange_code(code)
      response = Net::HTTP.post_form(
        URI(self.class.token_url),
        grant_type:    "authorization_code",
        code:          code,
        redirect_uri:  self.class.redirect_uri,
        client_id:     self.class.client_id,
        client_secret: self.class.client_secret
      )

      body = JSON.parse(response.body)
      raise "Token exchange failed: #{body['error'] || response.code}" if response.code != "200"

      { access_token: body.fetch("access_token") }
    end

    def fetch_userinfo(access_token)
      uri = URI(self.class.userinfo_url)
      req = Net::HTTP::Get.new(uri, "Authorization" => "Bearer #{access_token}", "Accept" => "application/json")
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |h| h.request(req) }
      raise "Failed to fetch identity: HTTP #{response.code}" if response.code != "200"

      JSON.parse(response.body)
    end

    def upsert_user(identity)
      sub     = identity.fetch("sub").to_s
      email   = identity.fetch("email")
      name    = identity["name"].presence || email
      payload = current_account_payload(identity)
      role    = normalize_role(payload&.dig("role"))

      RailsMcp::User.transaction do
        account = mirror_account(identity, payload)
        user    = RailsMcp::User.find_by(identity_id: sub)

        if user.nil?
          account.users.create!(identity_id: sub, email: email, name: name, role: role)
        else
          user.update!(email: email, name: name, account: account, role: role)
          user
        end
      end
    end

    # The account entry the user is currently acting under, picked from the
    # userinfo `accounts` list by `current_account_id` (falling back to the
    # first). Returns nil if the IdP sent no accounts.
    def current_account_payload(identity)
      current_id = identity["current_account_id"].to_s
      (identity["accounts"] || []).find { |a| a["id"].to_s == current_id } ||
        identity["accounts"]&.first
    end

    # Coerce the IdP-supplied role to a known value, defaulting to member for
    # anything missing or unrecognised.
    def normalize_role(role)
      RailsMcp::User::ROLES.include?(role) ? role : RailsMcp::User::DEFAULT_ROLE
    end

    # Find-or-create a local Account by the IdP's account id. Falls back to an
    # anonymous local account if the IdP didn't include accounts in userinfo —
    # the user can still onboard and be reassigned later.
    def mirror_account(identity, payload = current_account_payload(identity))
      column     = self.class.mirror_account_column
      current_id = identity["current_account_id"].to_s
      mirror_id  = payload&.dig("id")&.to_s.presence || current_id.presence
      name       = payload&.dig("name").presence || identity["email"]

      if mirror_id.present?
        account = RailsMcp::Account.find_or_initialize_by(column => mirror_id)
        account.name = name
        account.save!
        account
      else
        RailsMcp::Account.create!(name: name)
      end
    end
  end
end
