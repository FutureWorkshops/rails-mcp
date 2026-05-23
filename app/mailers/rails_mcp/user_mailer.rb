module RailsMcp
  class UserMailer < ApplicationMailer
    def invite_email(invitation_id:)
      @invitation = RailsMcp::Invitation.find(invitation_id)
      @app_name = RailsMcp.config.display_name
      @inviter_name = @invitation.invited_by&.name.presence || @invitation.invited_by&.email || @app_name
      @account_name = @invitation.account.name
      @accept_url = RailsMcp::Engine.routes.url_helpers.invitation_url(
        token: @invitation.token,
        host: ActionMailer::Base.default_url_options[:host] || "localhost",
        port: ActionMailer::Base.default_url_options[:port]
      )

      mail(
        to: @invitation.email,
        subject: "#{@inviter_name} invited you to join #{@account_name} on #{@app_name}"
      )
    end
  end
end
