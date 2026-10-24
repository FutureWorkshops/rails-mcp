module RailsMcp
  # CSRF-exempt base class that Doorkeeper's own controllers inherit from. Host
  # configures Doorkeeper with `base_controller "RailsMcp::OauthBaseController"`.
  #
  # Forces the host's application layout so the OAuth consent screen renders
  # with the host's chrome (nav, logo, design tokens). Without this Doorkeeper
  # falls back to its own near-empty "doorkeeper/application" layout and every
  # host's customised view appears unstyled.
  #
  # Two checks run here, before Doorkeeper sees an authorization request, so
  # every host gets them without touching its own Doorkeeper initializer:
  #
  # - The redirect URI of a self-registered (public) client must still be one
  #   RailsMcp::RedirectUris allows (ENG-01). Registration already refuses
  #   anything else; this catches clients registered before the rule, and
  #   makes narrowing allowed_redirect_hosts take effect at once. Answered with
  #   a page of our own, never Doorkeeper's error redirect, because the
  #   redirect is exactly what can't be trusted. Confidential clients are made
  #   by an operator, not by a stranger, and pass straight through.
  # - The signed-in user's standing at the identity provider (ENG-03). An
  #   expired session is reset first (RailsMcp::Authentication), so Doorkeeper
  #   sends the person to sign in again. A user the IdP says has left is
  #   signed out and has every token revoked; when the IdP can't be asked the
  #   request is refused for now (fail closed) and reported.
  class OauthBaseController < ::ApplicationController
    include RailsMcp::Authentication

    layout "application"

    skip_before_action :verify_authenticity_token, raise: false

    before_action :refuse_unapproved_redirect, if: :authorization_request?
    before_action :check_identity_standing, if: :authorization_request?

    private

    def authorization_request?
      controller_name == "authorizations" && %w[new create].include?(action_name)
    end

    def refuse_unapproved_redirect
      application = Doorkeeper::Application.find_by(uid: params[:client_id].to_s)
      return if application.nil? || application.confidential?

      redirect_uri = params[:redirect_uri].presence || application.redirect_uri.to_s.split.first
      return if RailsMcp::RedirectUris.allowed?(redirect_uri)

      Rails.logger.warn("[rails_mcp] authorization refused for application #{application.id}: redirect host not allowed")
      render_refusal(
        :bad_request,
        title: "This connection can't be authorised",
        message: "#{application.name.to_s.first(100)} asked for access to be sent to an address this server doesn't " \
                 "send access to. Nothing has been shared. If you were setting up a connector you trust, ask " \
                 "whoever runs this server to allow it."
      )
    end

    def check_identity_standing
      user = current_user
      return if user.nil? # Doorkeeper's authenticator sends them to sign in

      outcome, standing = RailsMcp::IdentityCheck.check(user)
      case outcome
      when :inactive
        RailsMcp::IdentityCheck.deactivate!(user, reason: "authorize#{" (#{standing.reason})" if standing&.reason}")
        reset_session
        render_refusal(
          :forbidden,
          title: "Your access has ended",
          message: "Your account no longer gives you access to #{RailsMcp.config.display_name}. " \
                   "If you think this is a mistake, ask your organisation's admin."
        )
      when :unknown
        RailsMcp::IdentityCheck.report_unknown(user, standing, where: "authorize")
        render_refusal(
          :service_unavailable,
          title: "We couldn't check your access",
          message: "We couldn't confirm your access just now, so nothing has been connected. Please try again in a few minutes."
        )
      end
    end

    def render_refusal(status, title:, message:)
      render "rails_mcp/oauth/refused", layout: "rails_mcp/doorkeeper", status: status,
                                        locals: { title: title, message: message }
    end
  end
end
