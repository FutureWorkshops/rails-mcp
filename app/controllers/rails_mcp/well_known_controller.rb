module RailsMcp
  class WellKnownController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false

    # RFC 8414 — OAuth 2.0 Authorization Server Metadata. The Doorkeeper routes
    # live in the host's top-level router (so the engine's `isolate_namespace`
    # doesn't try to resolve `Doorkeeper::TokensController` under our
    # namespace); reach them via `main_app`. Our own /oauth/register stays on
    # the engine's helpers.
    def oauth_authorization_server
      url_opts = { host: request.host, port: request.port, protocol: request.protocol }
      render json: {
        issuer: issuer,
        authorization_endpoint: main_app.oauth_authorization_url(**url_opts),
        token_endpoint:         main_app.oauth_token_url(**url_opts),
        registration_endpoint:  rails_mcp.oauth_register_url(**url_opts),
        revocation_endpoint:    main_app.oauth_revoke_url(**url_opts),
        introspection_endpoint: main_app.oauth_introspect_url(**url_opts),
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
