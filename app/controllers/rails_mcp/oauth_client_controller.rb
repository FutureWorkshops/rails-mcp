require "net/http"

module RailsMcp
  # Abstract base class for OAuth-client SSO controllers in MCP host apps.
  # Subclasses sign visitors in by doing an authorization-code round-trip
  # against an upstream OAuth provider (typically Cowork Hub), then upsert
  # a local RailsMcp::User keyed by the provider's stable `sub` claim and
  # mirror the user's current account onto a local RailsMcp::Account
  # keyed by a `groundwork_account_id`-style column.
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
  # The mirrored-account column defaults to `groundwork_account_id`. Override
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
    def self.mirror_account_column = :groundwork_account_id

    # IdP endpoint for the standing check (Groundwork: POST
    # /oauth/user_status). nil disables the check.
    def self.user_status_url = nil

    # Timeouts for every call to the IdP, so a hung Groundwork can't pin a
    # Puma thread for Net::HTTP's default minute.
    def self.http_open_timeout = 3
    def self.http_read_timeout = 5

    # What the IdP says about this user now, as a RailsMcp::IdentityStanding,
    # or nil when no user_status_url is configured (no check).
    #
    # Asks for the user's memberships too (`include=memberships`). A
    # Groundwork that knows the parameter answers with `accounts` (id, name
    # and role per account) and `home_account_id`, which lets the engine
    # follow a demotion or a removal from one organisation; an older one
    # ignores it and answers `active` alone, and only that is acted on.
    #
    # 200 is the answer. 404 means the IdP has no record of this user
    # authorising this app (or no such user), so it is treated as inactive.
    # Anything else, or no answer, is :unknown, which callers refuse on.
    def self.identity_status(user)
      return nil if user_status_url.blank?
      return RailsMcp::IdentityStanding.new(:unknown, reason: "user has no identity id") if user.identity_id.blank?

      uri = URI(user_status_url)
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(client_id, client_secret)
      request.set_form_data(sub: user.identity_id, include: "memberships")
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: http_open_timeout, read_timeout: http_read_timeout) { |http| http.request(request) }

      case response.code
      when "200" then standing_from(JSON.parse(response.body))
      when "404" then RailsMcp::IdentityStanding.new(:inactive, reason: "HTTP 404")
      else RailsMcp::IdentityStanding.new(:unknown, reason: "HTTP #{response.code}")
      end
    rescue StandardError => e
      RailsMcp::IdentityStanding.new(:unknown, reason: e.class.name)
    end

    def self.standing_from(body)
      return RailsMcp::IdentityStanding.new(:unknown, reason: "unexpected response") unless body.is_a?(Hash)
      return RailsMcp::IdentityStanding.new(:inactive, reason: "inactive") unless body["active"] == true

      accounts = body["accounts"].is_a?(Array) ? body["accounts"].select { |a| a.is_a?(Hash) && a["id"].present? } : nil
      RailsMcp::IdentityStanding.new(
        :active,
        accounts: accounts,
        home_account_id: body["home_account_id"],
        mirror_account_column: mirror_account_column
      )
    end

    SIGN_IN_FAILED = "Sign-in failed. Please try again.".freeze

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
      unless RailsMcp::OauthState.valid?(session.delete(self.class.state_session_key), params[:state])
        return redirect_to root_path, alert: "Invalid SSO state. Please try again."
      end

      if params[:error].present?
        Rails.logger.warn("#{self.class.name} sign-in refused by the identity provider: #{params[:error].to_s.first(100)}")
        return redirect_to root_path, alert: SIGN_IN_FAILED
      end

      tokens   = exchange_code(params[:code])
      identity = fetch_userinfo(tokens.fetch(:access_token))
      user     = upsert_user(identity)

      # Same standing check as the consent screen and every refresh, so
      # somebody the IdP lets sign in but who belongs to no organisation (or
      # whose role has changed since userinfo was cached) is handled the same
      # way here. :unknown is let through: they authenticated at the IdP a
      # moment ago, and authorize and refresh both fail closed on it.
      outcome, standing = RailsMcp::IdentityCheck.check(user)
      if outcome == :inactive
        RailsMcp::IdentityCheck.deactivate!(user, reason: "sign-in#{" (#{standing.reason})" if standing&.reason}")
        reset_session
        return redirect_to root_path, alert: "Your account no longer gives you access to #{RailsMcp.config.display_name}."
      end

      return_to = session[:return_to]
      reset_session
      RailsMcp::Authentication.start_session(session, user)

      redirect_to safe_return_to(return_to) || after_sign_in_path,
                  notice: "Signed in as #{user.email}."
    rescue StandardError => e
      # The detail (which can quote an upstream response body) goes to the
      # log, never to the person signing in.
      Rails.logger.error("#{self.class.name} callback failed: #{e.class}: #{e.message}")
      redirect_to root_path, alert: SIGN_IN_FAILED
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
      uri = URI(self.class.token_url)
      request = Net::HTTP::Post.new(uri)
      request.set_form_data(
        grant_type:    "authorization_code",
        code:          code,
        redirect_uri:  self.class.redirect_uri,
        client_id:     self.class.client_id,
        client_secret: self.class.client_secret
      )
      response = idp_request(uri, request)
      raise "Token exchange failed: HTTP #{response.code}" if response.code != "200"

      { access_token: JSON.parse(response.body).fetch("access_token") }
    end

    def fetch_userinfo(access_token)
      uri = URI(self.class.userinfo_url)
      request = Net::HTTP::Get.new(uri, "Authorization" => "Bearer #{access_token}", "Accept" => "application/json")
      response = idp_request(uri, request)
      raise "Failed to fetch identity: HTTP #{response.code}" if response.code != "200"

      JSON.parse(response.body)
    end

    def idp_request(uri, request)
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                      open_timeout: self.class.http_open_timeout,
                      read_timeout: self.class.http_read_timeout) { |http| http.request(request) }
    end

    def upsert_user(identity)
      sub     = identity.fetch("sub").to_s
      email   = identity.fetch("email")
      name    = identity["name"].presence || email
      payload = mirrored_account_payload(identity)
      role    = normalize_role(payload&.dig("role"))

      RailsMcp::User.transaction do
        user    = RailsMcp::User.find_by(identity_id: sub)
        account = mirror_account(identity, payload, existing: user&.account)

        if user.nil?
          account.users.create!(identity_id: sub, email: email, name: name, role: role)
        else
          user.update!(email: email, name: name, account: account, role: role)
          user
        end
      end
    end

    # The account to mirror, from the userinfo `accounts` list: the user's
    # home account first, then the one they're currently acting under, then
    # the first. `current_account_id` follows whatever account the user last
    # switched to on the IdP (a coach viewing a client), so it is only a
    # fallback for IdPs that don't send `home_account_id`. Returns nil if the
    # IdP sent no accounts.
    def mirrored_account_payload(identity)
      accounts = identity["accounts"] || []
      %w[home_account_id current_account_id].each do |key|
        id = identity[key].to_s
        next if id.empty?

        match = accounts.find { |a| a["id"].to_s == id }
        return match if match
      end
      accounts.first
    end

    # Coerce the IdP-supplied role to a known value, defaulting to member for
    # anything missing or unrecognised.
    def normalize_role(role)
      RailsMcp::User::ROLES.include?(role) ? role : RailsMcp::User::DEFAULT_ROLE
    end

    # Find-or-create a local Account by the IdP's account id; its name always
    # follows the IdP. If the IdP sent no accounts, keep the user's existing
    # local account, or create an anonymous one for a first sign-in.
    def mirror_account(identity, payload = mirrored_account_payload(identity), existing: nil)
      column    = self.class.mirror_account_column
      mirror_id = payload&.dig("id")&.to_s.presence
      name      = payload&.dig("name").presence || identity["email"]

      if mirror_id.present?
        account = RailsMcp::Account.find_or_initialize_by(column => mirror_id)
        account.name = name
        account.save!
        account
      else
        existing || RailsMcp::Account.create!(name: name)
      end
    end
  end
end
