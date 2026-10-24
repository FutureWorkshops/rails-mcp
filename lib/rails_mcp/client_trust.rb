module RailsMcp
  # Describes an OAuth client's redirect target for the consent screen.
  #
  # Dynamic Client Registration lets anyone register a client with any name, so
  # the client name alone ("Claude") proves nothing. The consent screen shows
  # where the authorization code will be sent and flags anything that isn't
  # one of Claude's own callbacks, a plain-http loopback address (a native
  # client on this machine), or an https host in
  # RailsMcp.config.trusted_redirect_hosts as unverified.
  #
  # https://localhost is deliberately not trusted: a native client listens
  # over plain http, and a certificate for "localhost" proves nothing.
  module ClientTrust
    module_function

    def redirect_host(redirect_uri)
      URI.parse(redirect_uri.to_s).host.to_s.downcase
    rescue URI::InvalidURIError
      ""
    end

    def trusted?(redirect_uri)
      return true if RedirectUris.first_party_callback?(redirect_uri)
      return true if RedirectUris.loopback_redirect?(redirect_uri)

      uri = URI.parse(redirect_uri.to_s)
      host = uri.host.to_s.downcase
      return false if host.blank? || uri.scheme != "https"
      return false if RedirectUris.loopback_host?(uri.hostname)

      RailsMcp.config.trusted_redirect_hosts.any? do |trusted|
        host == trusted || host.end_with?(".#{trusted}")
      end
    rescue URI::InvalidURIError
      false
    end
  end
end
