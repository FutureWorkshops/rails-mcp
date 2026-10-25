module RailsMcp
  # Raised to refuse a refresh; Doorkeeper renders it as an OAuth
  # `invalid_grant`, which makes the MCP client ask the user to reconnect.
  class RefreshRefused < Doorkeeper::Errors::DoorkeeperError
    def type = :invalid_grant
  end

  # Raised when the identity provider can't confirm the user's standing.
  # Answered with 503 `temporarily_unavailable` rather than `invalid_grant`,
  # and the refresh token is left as it was, so the client can retry once the
  # IdP is back instead of the user having to reconnect.
  class RefreshUnavailable < Doorkeeper::Errors::DoorkeeperError
    class Response < Doorkeeper::OAuth::ErrorResponse
      def status = :service_unavailable
    end

    def type = :temporarily_unavailable

    def response
      Response.new(name: type)
    end
  end

  # Policy applied to every refresh_token grant (prepended onto
  # Doorkeeper::OAuth::RefreshTokenRequest by the engine):
  #
  # - Idle expiry: a refresh token older than config.refresh_token_idle_days
  #   is refused. Each refresh issues a new token row, so a token's age is the
  #   time since the connection was last used.
  # - Standing: config.identity_status is asked about the user (see
  #   RailsMcp::IdentityCheck). Inactive refuses the refresh, revokes all of
  #   the user's tokens and runs on_user_deactivated. When the IdP sends
  #   memberships, the local role and mirrored account are updated first, so
  #   a demotion takes effect on this refresh. Unknown (IdP unreachable or
  #   answering with an error) refuses the refresh without revoking, and is
  #   logged and reported: failing open let every leaver keep refreshing for
  #   as long as Groundwork was unreachable or the app's secret was wrong.
  # - Reuse detection: presenting a refresh token that has already been
  #   rotated away revokes every token that user holds for that client, the
  #   standard response to a possibly stolen refresh token.
  module RefreshTokenPolicy
    module_function

    def enforce!(token)
      if (days = RailsMcp.config.refresh_token_idle_days) && token.created_at < days.to_i.days.ago
        token.revoke
        raise RefreshRefused, "refresh token idle for more than #{days} days"
      end

      return unless RailsMcp.config.identity_status

      user = RailsMcp::User.find_by(id: token.resource_owner_id)
      unless user
        revoke_all_for_owner!(token.resource_owner_id)
        raise RefreshRefused, "user no longer exists"
      end

      outcome, standing = RailsMcp::IdentityCheck.check(user)
      case outcome
      when :inactive
        RailsMcp::IdentityCheck.deactivate!(user, reason: "refresh#{" (#{standing.reason})" if standing&.reason}")
        raise RefreshRefused, "user is no longer active"
      when :unknown
        RailsMcp::IdentityCheck.report_unknown(user, standing, where: "refresh")
        raise RefreshUnavailable, "identity provider unavailable"
      end
    end

    def revoke_family!(token)
      revoked = Doorkeeper::AccessToken
                  .where(resource_owner_id: token.resource_owner_id, application_id: token.application_id, revoked_at: nil)
                  .update_all(revoked_at: Time.current)
      Rails.logger.warn("[rails_mcp] refresh token reuse for user #{token.resource_owner_id}, application #{token.application_id}: revoked #{revoked} token(s)")
    end

    def revoke_all_for_owner!(owner_id)
      now = Time.current
      Doorkeeper::AccessToken.where(resource_owner_id: owner_id, revoked_at: nil).update_all(revoked_at: now)
      Doorkeeper::AccessGrant.where(resource_owner_id: owner_id, revoked_at: nil).update_all(revoked_at: now)
    end

    # Prepended onto Doorkeeper::OAuth::RefreshTokenRequest.
    module RequestHooks
      private

      def validate_token
        RailsMcp::RefreshTokenPolicy.revoke_family!(refresh_token) if refresh_token.present? && refresh_token.revoked?
        super
      end

      def before_successful_response
        RailsMcp::RefreshTokenPolicy.enforce!(refresh_token)
        super
      end
    end
  end
end
