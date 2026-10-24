module RailsMcp
  module Oauth
    # RFC 7591 dynamic client registration. Claude Desktop POSTs here on first
    # connection with its redirect URI; we create a Doorkeeper::Application and
    # return its public client_id. PKCE means no secret is issued.
    #
    # Registration needs no authentication, so where a client may have its
    # codes sent is restricted (RailsMcp::RedirectUris): Claude's own
    # callbacks, plain-http loopback, and https hosts the operator lists in
    # allowed_redirect_hosts. OauthBaseController checks the same rule again
    # at /oauth/authorize.
    class ClientsController < RailsMcp::ApplicationController
      skip_before_action :verify_authenticity_token, raise: false

      DEFAULT_GRANT_TYPES = %w[authorization_code].freeze
      ALLOWED_GRANT_TYPES = %w[authorization_code refresh_token].freeze

      # Hard cap on client_name to bound the OAuth authorize page.
      MAX_CLIENT_NAME_LENGTH = 100

      # Bounds on what one unauthenticated registration may store.
      MAX_REDIRECT_URIS = 5
      MAX_REDIRECT_URI_LENGTH = 2048

      def create
        attrs = registration_params
        return render_error("invalid_client_metadata", "the request body must be a JSON object") unless attrs

        raw_uris = attrs["redirect_uris"]
        raw_uris = [ raw_uris ] if raw_uris.is_a?(String)
        unless raw_uris.nil? || (raw_uris.is_a?(Array) && raw_uris.all? { |uri| uri.is_a?(String) })
          return render_error("invalid_redirect_uri", "redirect_uris must be a list of strings")
        end

        redirect_uris = Array(raw_uris).reject(&:blank?)
        return render_error("invalid_redirect_uri", "redirect_uris is required") if redirect_uris.empty?

        if redirect_uris.size > MAX_REDIRECT_URIS || redirect_uris.any? { |uri| uri.length > MAX_REDIRECT_URI_LENGTH }
          return render_error(
            "invalid_redirect_uri",
            "at most #{MAX_REDIRECT_URIS} redirect_uris of up to #{MAX_REDIRECT_URI_LENGTH} characters each"
          )
        end

        if redirect_uris.any? { |uri| !RailsMcp::RedirectUris.allowed?(uri) }
          return render_error(
            "invalid_redirect_uri",
            "redirect_uris must be Claude's connector callback, a loopback address over http, " \
            "or an https URL on a host this server allows"
          )
        end

        client_name = attrs["client_name"].is_a?(String) ? attrs["client_name"].strip : ""
        if client_name.length > MAX_CLIENT_NAME_LENGTH
          return render_error(
            "invalid_client_metadata",
            "client_name must be #{MAX_CLIENT_NAME_LENGTH} characters or fewer"
          )
        end

        grant_types = Array(attrs["grant_types"]).presence || DEFAULT_GRANT_TYPES
        if (grant_types - ALLOWED_GRANT_TYPES).any?
          return render_error(
            "invalid_client_metadata",
            "grant_types must be a subset of #{ALLOWED_GRANT_TYPES.join(', ')}"
          )
        end

        scope = (attrs["scope"].is_a?(String) && attrs["scope"].presence) || RailsMcp.config.scopes.join(" ")

        application = Doorkeeper::Application.new(
          name:         client_name.presence || "MCP client",
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

      # The parsed body, {} when there is none, or nil when it isn't a JSON
      # object (an array or a bare value used to raise and answer 500).
      def registration_params
        body = request.raw_post
        return {} if body.blank?

        parsed = JSON.parse(body)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
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
