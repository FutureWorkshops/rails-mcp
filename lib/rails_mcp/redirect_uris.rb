require "uri"

module RailsMcp
  # The rules for where an authorization code may be sent to a client that
  # registered itself (ENG-01).
  #
  # Dynamic Client Registration (POST /oauth/register, RFC 7591) needs no
  # authentication: anybody on the internet can create a client. If that
  # client could name any redirect URI, an attacker could register one called
  # "Claude" pointing at their own server, send somebody the authorize link,
  # and walk away with a read+write token after one click on the consent
  # screen. So a self-registered client may only send codes to:
  #
  # - Claude's own connector callbacks (FIRST_PARTY_CALLBACKS), matched
  #   exactly: scheme, host, port and path. A whole host would let any open
  #   redirect on it become a way out.
  # - Any https URI (port 443) on a host listed in
  #   RailsMcp.config.allowed_redirect_hosts, which defaults to the
  #   comma-separated OAUTH_DCR_ALLOWED_REDIRECT_HOSTS environment variable,
  #   so another connector (Grok, say) can be allowed without a deploy. The
  #   operator vouches for the whole host, which is why it is never a default.
  # - A loopback address over plain http on any port (RFC 8252 section 7.3):
  #   native and CLI clients such as Claude Code listen on a random local
  #   port. A code sent to the user's own machine never leaves it.
  #
  # The same rules as Groundwork's Oauth::RedirectUris, so a connector that
  # works against one works against the other.
  module RedirectUris
    ENV_KEY = "OAUTH_DCR_ALLOWED_REDIRECT_HOSTS".freeze

    FIRST_PARTY_CALLBACKS = %w[
      https://claude.ai/api/mcp/auth_callback
      https://claude.com/api/mcp/auth_callback
    ].freeze

    # URI#hostname strips the brackets from an IPv6 literal, so "[::1]" is
    # matched as "::1".
    LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze

    module_function

    # True when a self-registered client may use `uri_string` as a redirect.
    def allowed?(uri_string)
      uri = parse(uri_string)
      return false unless uri && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil?

      loopback?(uri) || first_party?(uri) || operator_allowed?(uri)
    end

    # Every URI in Doorkeeper's newline-separated redirect_uri column passes.
    def all_allowed?(redirect_uri_column)
      uris = redirect_uri_column.to_s.split
      uris.any? && uris.all? { |uri| allowed?(uri) }
    end

    # Exactly one of Claude's own callbacks.
    def first_party_callback?(uri_string)
      uri = parse(uri_string)
      uri.present? && first_party?(uri)
    end

    # A plain http loopback address, where native clients listen.
    def loopback_redirect?(uri_string)
      uri = parse(uri_string)
      uri.present? && loopback?(uri)
    end

    # For Doorkeeper's force_ssl_in_redirect_uri: should this URI be refused
    # for being plain http? Only in production, and never for a loopback
    # address, which native clients can't serve over TLS and which never
    # crosses a network.
    #
    #   force_ssl_in_redirect_uri { |uri| RailsMcp::RedirectUris.force_ssl?(uri) }
    def force_ssl?(uri, env: Rails.env)
      env.production? && !loopback_host?(uri.try(:hostname))
    end

    def loopback_host?(host)
      LOOPBACK_HOSTS.include?(host.to_s.downcase)
    end

    def parse(uri_string)
      URI.parse(uri_string.to_s.strip)
    rescue URI::InvalidURIError
      nil
    end

    def loopback?(uri)
      uri.scheme == "http" && loopback_host?(uri.hostname)
    end

    def first_party?(uri)
      FIRST_PARTY_CALLBACKS.include?(uri.to_s)
    end

    def operator_allowed?(uri)
      uri.scheme == "https" && uri.port == 443 &&
        RailsMcp.config.allowed_redirect_hosts.include?(uri.hostname.to_s.downcase)
    end

    private_class_method :parse, :loopback?, :first_party?, :operator_allowed?
  end
end
