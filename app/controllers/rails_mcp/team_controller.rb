module RailsMcp
  class TeamController < ApplicationController
    include RailsMcp::OnboardingGate

    before_action :require_sign_in
    before_action :require_onboarding

    def index
      account = current_user.account
      @account = account
      @members = account.users.order(:created_at)
      @invitations = account.invitations.pending.order(created_at: :desc)
    end

    def update_account
      account = current_user.account
      name = params[:name].to_s.strip

      if account.update(name: name)
        redirect_to RailsMcp::Engine.routes.url_helpers.team_path, notice: "Account name saved."
      else
        redirect_to RailsMcp::Engine.routes.url_helpers.team_path,
                    alert: account.errors.full_messages.to_sentence
      end
    end

    def create_invitation
      account = current_user.account
      email = params[:email].to_s.strip.downcase

      if email.blank?
        return redirect_to RailsMcp::Engine.routes.url_helpers.team_path, alert: "Email is required."
      end

      if account.users.where("LOWER(email) = ?", email).exists?
        return redirect_to RailsMcp::Engine.routes.url_helpers.team_path,
                           alert: "#{email} is already on the team."
      end

      if account.invitations.pending.where("LOWER(email) = ?", email).exists?
        return redirect_to RailsMcp::Engine.routes.url_helpers.team_path,
                           alert: "There's already a pending invitation for #{email}."
      end

      invitation = account.invitations.build(email: email, invited_by: current_user)

      if invitation.save
        RailsMcp::UserMailer.invite_email(invitation_id: invitation.id).deliver_later
        redirect_to RailsMcp::Engine.routes.url_helpers.team_path,
                    notice: "Invitation sent to #{email}."
      else
        redirect_to RailsMcp::Engine.routes.url_helpers.team_path,
                    alert: invitation.errors.full_messages.to_sentence
      end
    end

    def destroy_invitation
      invitation = current_user.account.invitations.find(params[:id])
      invitation.revoke! if invitation.pending?
      redirect_to RailsMcp::Engine.routes.url_helpers.team_path,
                  notice: "Invitation revoked."
    end
  end
end
