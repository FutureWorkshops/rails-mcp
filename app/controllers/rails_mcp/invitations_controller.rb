module RailsMcp
  class InvitationsController < ApplicationController
    def show
      @invitation = RailsMcp::Invitation.find_by(token: params[:token])

      @state =
        if @invitation.nil?       then :not_found
        elsif @invitation.accepted? then :accepted
        elsif @invitation.revoked?  then :revoked
        elsif @invitation.expired?  then :expired
        else                              :claimable
        end

      if @state == :claimable
        session[RailsMcp::Invitation::SESSION_KEY] = @invitation.token
      else
        session.delete(RailsMcp::Invitation::SESSION_KEY)
      end

      status = @state == :not_found ? :not_found : :ok
      render :show, status: status
    end
  end
end
