module RailsMcp
  # Reported to Rails.error when the identity provider can't confirm a user's
  # standing, so a rotated client secret or a Groundwork outage is noticed
  # rather than silently letting leavers through (ENG-04).
  class IdentityUnavailable < StandardError; end

  # Applies the identity provider's view of a user to this app. Used at every
  # point where a user gains or renews access: the refresh grant
  # (RefreshTokenPolicy), the consent screen (OauthBaseController) and SSO
  # sign-in (OauthClientController).
  #
  # The outcome is one of:
  #
  # - :active: still a member somewhere. When the IdP sent memberships, the
  #   local role and mirrored account have been brought up to date, so a
  #   demotion or a removal from one organisation takes effect here (ENG-02).
  # - :inactive: deleted, or a member of nothing. The caller refuses, and
  #   should call #deactivate! to revoke everything.
  # - :unknown: the IdP couldn't be asked. The caller refuses without
  #   revoking (fail closed, but recoverable), after #report_unknown.
  # - :unchecked: no identity_status hook is configured.
  module IdentityCheck
    module_function

    def standing_for(user)
      checker = RailsMcp.config.identity_status
      return nil unless checker

      IdentityStanding.wrap(checker.call(user))
    rescue StandardError => e
      IdentityStanding.new(:unknown, reason: "#{e.class}: #{e.message}")
    end

    # Asks the IdP about `user` and reconciles the local mirror. Returns
    # [outcome, standing].
    def check(user)
      standing = standing_for(user)
      return [ :unchecked, nil ] if standing.nil?

      [ reconcile!(user, standing), standing ]
    rescue StandardError => e
      Rails.logger.error("[rails_mcp] identity sync failed for user #{user.id}: #{e.class}: #{e.message}")
      [ :unknown, IdentityStanding.new(:unknown, reason: "sync failed: #{e.class}") ]
    end

    def reconcile!(user, standing)
      return :inactive if standing.inactive?
      return :unknown if standing.unknown?
      return :active unless standing.memberships?
      return :inactive if standing.accounts.empty?

      column  = standing.mirror_account_column
      current = user.account&.public_send(column).to_s
      entry   = standing.accounts.find { |account| account["id"].to_s == current } if current.present?
      entry ||= preferred_account(standing)

      account = mirror_account(column, entry, fallback_name: user.email)
      role    = RailsMcp::User::ROLES.include?(entry["role"]) ? entry["role"] : RailsMcp::User::DEFAULT_ROLE

      if user.account_id != account.id || user.role != role
        Rails.logger.info(
          "[rails_mcp] identity sync: user #{user.id} account #{user.account_id}->#{account.id}, role #{user.role}->#{role}"
        )
        # Only these two columns: an unrelated validation (an email the IdP
        # has since changed, say) must not stop a demotion from landing.
        user.update_columns(account_id: account.id, role: role, updated_at: Time.current)
      end

      :active
    end

    # Revokes every token and grant the user holds and runs the host's
    # on_user_deactivated hook (to delete stored upstream credentials, say).
    # A failing hook is reported, never allowed to stop the revocation.
    def deactivate!(user_or_id, reason:)
      user = user_or_id.is_a?(RailsMcp::User) ? user_or_id : RailsMcp::User.find_by(id: user_or_id)
      owner_id = user&.id || user_or_id

      RailsMcp::RefreshTokenPolicy.revoke_all_for_owner!(owner_id)
      Rails.logger.warn("[rails_mcp] user #{owner_id} is no longer active at the identity provider (#{reason}): tokens revoked")

      hook = RailsMcp.config.on_user_deactivated
      return unless hook && user

      begin
        hook.call(user)
      rescue StandardError => e
        Rails.logger.error("[rails_mcp] on_user_deactivated failed for user #{owner_id}: #{e.class}: #{e.message}")
        Rails.error.report(e, handled: true, context: { rails_mcp_user_id: owner_id })
      end
    end

    def report_unknown(user, standing, where:)
      detail = standing&.reason.presence || "no answer"
      Rails.logger.warn("[rails_mcp] #{where} refused for user #{user&.id}: identity provider could not confirm standing (#{detail})")
      Rails.error.report(
        IdentityUnavailable.new("identity provider could not confirm standing at #{where}: #{detail}"),
        handled: true, severity: :warning, context: { rails_mcp_user_id: user&.id }
      )
    end

    # The same preference as SSO sign-in: the home account, else the first.
    def preferred_account(standing)
      home = standing.home_account_id
      (home && standing.accounts.find { |account| account["id"].to_s == home }) || standing.accounts.first
    end

    def mirror_account(column, entry, fallback_name:)
      account = RailsMcp::Account.find_or_initialize_by(column => entry["id"].to_s)
      account.name = (entry["name"].presence || account.name.presence || fallback_name).to_s.first(100)
      account.save! if account.changed?
      account
    end

    private_class_method :preferred_account, :mirror_account
  end
end
