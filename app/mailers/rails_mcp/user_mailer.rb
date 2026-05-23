module RailsMcp
  class UserMailer < ApplicationMailer
    def invite_email(invitation_id:)
      @invitation = RailsMcp::Invitation.find(invitation_id)
      @app_name = RailsMcp.config.display_name
      @inviter_name = @invitation.invited_by&.name.presence || @invitation.invited_by&.email || @app_name
      @account_name = @invitation.account.name
      host = ActionMailer::Base.default_url_options[:host]
      raise "ActionMailer::Base.default_url_options[:host] is not configured; cannot build invitation URL" if host.blank?

      @accept_url = RailsMcp::Engine.routes.url_helpers.invitation_url(
        token: @invitation.token,
        host: host,
        port: ActionMailer::Base.default_url_options[:port],
        protocol: ActionMailer::Base.default_url_options[:protocol]
      )

      mail(
        to: @invitation.email,
        subject: "#{@inviter_name} invited you to join #{@account_name} on #{@app_name}"
      )
    end
  end
end
