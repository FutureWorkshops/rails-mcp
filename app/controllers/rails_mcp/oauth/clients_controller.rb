module RailsMcp
  module Oauth
    # RFC 7591 dynamic client registration. Claude Desktop POSTs here on first
    # connection with its redirect URI; we create a Doorkeeper::Application and
    # return its public client_id. PKCE means no secret is issued.
    class ClientsController < RailsMcp::ApplicationController
      skip_before_action :verify_authenticity_token, raise: false

      DEFAULT_GRANT_TYPES = %w[authorization_code].freeze
      ALLOWED_GRANT_TYPES = %w[authorization_code refresh_token].freeze

      # Hard cap on client_name to bound the OAuth authorize page.
      MAX_CLIENT_NAME_LENGTH = 100

      # Loopback hosts that we accept over plain http in non-production environments
      # (Claude Desktop sometimes registers `http://localhost:NNNN/callback`).
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

      def create
        attrs = registration_params

        redirect_uris = Array(attrs["redirect_uris"]).reject(&:blank?)
        return render_error("invalid_redirect_uri", "redirect_uris is required") if redirect_uris.empty?

        if (invalid = invalid_redirect_uris(redirect_uris)).any?
          return render_error(
            "invalid_redirect_uri",
            "redirect_uris must be absolute https:// URLs with a host (#{invalid.join(', ')} rejected)"
          )
        end

        client_name = attrs["client_name"].to_s.strip
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

        scope = attrs["scope"].presence || RailsMcp.config.scopes.join(" ")

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

      def registration_params
        body = request.raw_post
        return {} if body.blank?

        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end

      # Returns the subset of uris that fail validation. A uri is valid when:
      # - it parses
      # - scheme is `https` (any environment), or `http` with a loopback host
      #   (development/test only — never accepted in production)
      # - host is present
      # - no userinfo / fragment
      def invalid_redirect_uris(uris)
        uris.reject { |uri| valid_redirect_uri?(uri) }
      end

      def valid_redirect_uri?(raw)
        uri = URI.parse(raw.to_s)
        return false if uri.host.blank?
        return false if uri.userinfo.present?
        return false if uri.fragment.present?

        case uri.scheme
        when "https"
          true
        when "http"
          !Rails.env.production? && LOOPBACK_HOSTS.include?(uri.host.downcase)
        else
          false
        end
      rescue URI::InvalidURIError
        false
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
