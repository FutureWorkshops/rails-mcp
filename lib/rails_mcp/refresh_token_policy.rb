module RailsMcp
  # Raised to refuse a refresh; Doorkeeper renders it as an OAuth
  # `invalid_grant`, which makes the MCP client ask the user to reconnect.
  class RefreshRefused < Doorkeeper::Errors::DoorkeeperError
    def type = :invalid_grant
  end

  # Policy applied to every refresh_token grant (prepended onto
  # Doorkeeper::OAuth::RefreshTokenRequest by the engine):
  #
  # - Idle expiry: a refresh token older than config.refresh_token_idle_days
  #   is refused. Each refresh issues a new token row, so a token's age is the
  #   time since the connection was last used.
  # - Leavers: config.identity_status is asked whether the user is still
  #   active at the identity provider (Groundwork). :inactive refuses the
  #   refresh and revokes all of the user's tokens; :unknown (IdP unreachable,
  #   not configured) lets it through so an IdP outage can't lock users out.
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

      checker = RailsMcp.config.identity_status
      return unless checker

      user = RailsMcp::User.find_by(id: token.resource_owner_id)
      status = user ? checker.call(user) : :inactive
      return unless status == :inactive

      revoke_all_for_owner!(token.resource_owner_id)
      Rails.logger.warn("[rails_mcp] refresh refused: user #{token.resource_owner_id} is no longer active at the identity provider")
      raise RefreshRefused, "user is no longer active"
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
