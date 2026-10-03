module RailsMcp
  # Describes an OAuth client's redirect target for the consent screen.
  #
  # Dynamic Client Registration lets anyone register a client with any name, so
  # the client name alone ("Claude") proves nothing. The consent screen shows
  # where the authorization code will be sent and flags hosts outside
  # RailsMcp.config.trusted_redirect_hosts as unverified.
  module ClientTrust
    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze

    module_function

    def redirect_host(redirect_uri)
      URI.parse(redirect_uri.to_s).host.to_s.downcase
    rescue URI::InvalidURIError
      ""
    end

    def trusted?(redirect_uri)
      host = redirect_host(redirect_uri)
      return false if host.blank?
      return true if LOOPBACK_HOSTS.include?(host)

      RailsMcp.config.trusted_redirect_hosts.any? do |trusted|
        host == trusted || host.end_with?(".#{trusted}")
      end
    end
  end
end
