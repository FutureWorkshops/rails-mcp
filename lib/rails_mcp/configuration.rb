module RailsMcp
  # Configuration is intentionally a plain object with lazy defaults: hosts can set
  # any subset of values; unset ones derive from `server_name` at read time.
  class Configuration
    attr_writer :server_name, :server_version, :display_name, :resource_name,
                :scopes, :scope_descriptions, :tools, :tool_error_handler,
                :mailer_from, :suggested_account_name, :sign_in_path,
                :trusted_redirect_hosts, :refresh_token_idle_days, :identity_status,
                :allowed_redirect_hosts, :session_lifetime, :on_user_deactivated,
                :mcp_max_body_bytes

    def server_name
      @server_name || Rails.application.class.module_parent_name.underscore
    end

    def server_version
      @server_version || "0.1.0"
    end

    def display_name
      @display_name || server_name.titleize
    end

    def resource_name
      @resource_name || "#{display_name} Server"
    end

    def scopes
      @scopes || %w[read write]
    end

    def scope_descriptions
      @scope_descriptions || {}
    end

    def tools
      @tools || -> { RailsMcp::Registry.all_tools }
    end

    # `tools` may be a list, a zero-arity proc (same tools for everyone), or a
    # proc taking the MCP user, so a host can expose a different tool set per
    # user. The MCP controller resolves both tools/list and tools/call through
    # this, so a tool left out for a user is neither listed nor callable.
    def tool_classes(user = nil)
      list =
        if !tools.respond_to?(:call) then tools
        elsif tools.arity.zero?      then tools.call
        else                              tools.call(user)
        end
      Array(list)
    end

    def tool_error_handler
      @tool_error_handler
    end

    # Deprecated no-ops: `mailer_from` and `suggested_account_name` only fed
    # the removed invitation mailer and onboarding page. The writers stay so
    # existing host initializers don't break.

    def sign_in_path
      @sign_in_path || ->(_request) { "/sign_in" }
    end

    # Refresh tokens unused for this many days are refused (nil disables).
    def refresh_token_idle_days
      defined?(@refresh_token_idle_days) ? @refresh_token_idle_days : 30
    end

    # ->(user) { RailsMcp::IdentityStanding | :active | :inactive | :unknown },
    # asked on every refresh, at the consent screen and at SSO sign-in.
    # Hosts point it at their SSO controller:
    #   c.identity_status = ->(user) { GroundworkOauthController.identity_status(user) }
    # :unknown fails closed (the refresh or authorization is refused, and
    # reported). nil disables the check.
    def identity_status
      @identity_status
    end

    # Called with the RailsMcp::User once the identity provider says they
    # have left (deleted, or a member of nothing), after their MCP tokens are
    # revoked. Hosts use it to delete stored upstream credentials:
    #   c.on_user_deactivated = ->(user) { user.connections.destroy_all }
    def on_user_deactivated
      @on_user_deactivated
    end

    # Hosts a self-registered OAuth client may send codes to over https, on
    # top of Claude's own callbacks and loopback (see RailsMcp::RedirectUris).
    # Defaults to the comma-separated OAUTH_DCR_ALLOWED_REDIRECT_HOSTS
    # environment variable, read on each check.
    def allowed_redirect_hosts
      list = @allowed_redirect_hosts.nil? ? ENV.fetch(RedirectUris::ENV_KEY, "").split(",") : Array(@allowed_redirect_hosts)
      list.map { |host| host.to_s.strip.downcase }.reject(&:empty?)
    end

    # Absolute lifetime of the browser session the engine signs people in
    # with. Past it the session is reset and the person signs in through the
    # identity provider again, which is what stops a leaver's old cookie
    # minting fresh MCP tokens. nil disables (not recommended).
    def session_lifetime
      defined?(@session_lifetime) ? @session_lifetime : 12.hours
    end

    # Largest POST /mcp body accepted, in bytes; bigger is refused with 413
    # before anything is parsed.
    def mcp_max_body_bytes
      @mcp_max_body_bytes || 1.megabyte
    end

    # Redirect hosts the consent screen treats as known MCP clients (https
    # only, subdomains match). Claude's own callbacks and plain-http loopback
    # are always treated as known; anything else is shown as unverified.
    def trusted_redirect_hosts
      @trusted_redirect_hosts || %w[claude.ai claude.com]
    end
  end
end
