module RailsMcp
  module Oauth
    # RFC 7591 dynamic client registration. Claude Desktop POSTs here on first
    # connection with its redirect URI; we create a Doorkeeper::Application and
    # return its public client_id. PKCE means no secret is issued.
    class ClientsController < RailsMcp::ApplicationController
      skip_before_action :verify_authenticity_token, raise: false

      DEFAULT_GRANT_TYPES = %w[authorization_code].freeze
      ALLOWED_GRANT_TYPES = %w[authorization_code refresh_token].freeze

      def create
        attrs = registration_params

        redirect_uris = Array(attrs["redirect_uris"]).reject(&:blank?)
        return render_error("invalid_redirect_uri", "redirect_uris is required") if redirect_uris.empty?

        grant_types = Array(attrs["grant_types"]).presence || DEFAULT_GRANT_TYPES
        if (grant_types - ALLOWED_GRANT_TYPES).any?
          return render_error(
            "invalid_client_metadata",
            "grant_types must be a subset of #{ALLOWED_GRANT_TYPES.join(', ')}"
          )
        end

        scope = attrs["scope"].presence || RailsMcp.config.scopes.join(" ")

        application = Doorkeeper::Application.new(
          name:         attrs["client_name"].presence || "MCP client",
          redirect_uri: redirect_uris.join("\n"),
          scopes:       scope,
          confidential: false
        )

        if application.save
          render json: registration_response(application, redirect_uris, grant_types, scope),
                 status: :created
        else
          render_error("invalid_client_metadata", application.errors.full_messages.join(", "))
        end
      end

      private

      def registration_params
        body = request.raw_post
        return {} if body.blank?

        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end

      def registration_response(application, redirect_uris, grant_types, scope)
        {
          client_id: application.uid,
          client_id_issued_at: application.created_at.to_i,
          client_name: application.name,
          redirect_uris: redirect_uris,
          grant_types: grant_types,
          response_types: %w[code],
          token_endpoint_auth_method: "none",
          scope: scope
        }
      end

      def render_error(code, description)
        render json: { error: code, error_description: description },
               status: :bad_request
      end
    end
  end
end
