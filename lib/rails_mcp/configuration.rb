module RailsMcp
  # Configuration is intentionally a plain object with lazy defaults: hosts can set
  # any subset of values; unset ones derive from `server_name` at read time.
  class Configuration
    attr_writer :server_name, :server_version, :display_name, :resource_name,
                :scopes, :scope_descriptions, :tools, :tool_error_handler,
                :mailer_from, :suggested_account_name, :sign_in_path,
                :trusted_redirect_hosts, :refresh_token_idle_days, :identity_status

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

    # Redirect hosts the consent screen treats as known MCP clients. Anything
    # else (bar loopback) is shown as unverified. Subdomains match.
    # Refresh tokens unused for this many days are refused (nil disables).
    def refresh_token_idle_days
      defined?(@refresh_token_idle_days) ? @refresh_token_idle_days : 30
    end

    # ->(user) { :active | :inactive | :unknown }, asked on every refresh.
    # Hosts usually point it at their SSO controller, e.g.
    #   c.identity_status = ->(user) { GroundworkOauthController.identity_status(user) }
    def identity_status
      @identity_status
    end

    def trusted_redirect_hosts
      @trusted_redirect_hosts || %w[claude.ai claude.com]
    end
  end
end
