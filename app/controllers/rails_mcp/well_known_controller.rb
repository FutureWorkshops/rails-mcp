module RailsMcp
  class WellKnownController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false

    # RFC 8414 — OAuth 2.0 Authorization Server Metadata.
    def oauth_authorization_server
      helpers = RailsMcp::Engine.routes.url_helpers
      render json: {
        issuer: issuer,
        authorization_endpoint: helpers.oauth_authorization_url(host: request.host, port: request.port, protocol: request.protocol),
        token_endpoint:         helpers.oauth_token_url(host: request.host, port: request.port, protocol: request.protocol),
        registration_endpoint:  helpers.oauth_register_url(host: request.host, port: request.port, protocol: request.protocol),
        revocation_endpoint:    helpers.oauth_revoke_url(host: request.host, port: request.port, protocol: request.protocol),
        introspection_endpoint: helpers.oauth_introspect_url(host: request.host, port: request.port, protocol: request.protocol),
        response_types_supported: %w[code],
        grant_types_supported: %w[authorization_code refresh_token],
        code_challenge_methods_supported: %w[S256],
        token_endpoint_auth_methods_supported: %w[none],
        scopes_supported: RailsMcp.config.scopes,
        service_documentation: issuer
      }
    end

    # RFC 9728 — OAuth 2.0 Protected Resource Metadata.
    def oauth_protected_resource
      render json: {
        resource: mcp_resource_url,
        resource_name: RailsMcp.config.resource_name,
        authorization_servers: [ issuer ],
        scopes_supported: RailsMcp.config.scopes,
        bearer_methods_supported: %w[header],
        resource_documentation: issuer
      }
    end

    private

    def issuer
      request.base_url
    end

    def mcp_resource_url
      "#{issuer}/mcp"
    end
  end
end
