module RailsMcp
  module Authentication
    extend ActiveSupport::Concern

    SIGNED_IN_AT_KEY = :signed_in_at

    included do
      helper_method :current_user, :signed_in? if respond_to?(:helper_method)
    end

    # The engine's browser session has an absolute lifetime
    # (RailsMcp.config.session_lifetime, 12 hours by default), stamped at SSO
    # sign-in. Past it, or with no stamp at all (a cookie from before 1.0),
    # the session is reset and the person signs in through the identity
    # provider again. Without it a leaver's cookie kept working for as long
    # as the browser kept it, and could mint fresh MCP tokens at
    # /oauth/authorize long after Groundwork had let them go.
    def self.session_expired?(session, now: Time.current)
      lifetime = RailsMcp.config.session_lifetime
      return false if lifetime.nil?

      stamp = session[SIGNED_IN_AT_KEY]
      return true if stamp.blank?

      signed_in_at = Time.zone.at(stamp.to_i)
      signed_in_at < now - lifetime || signed_in_at > now + 1.minute
    end

    # Starts a session for `user`. The one way the engine signs somebody in.
    def self.start_session(session, user, now: Time.current)
      session[:user_id] = user.id
      session[SIGNED_IN_AT_KEY] = now.to_i
    end

    # For Doorkeeper's resource_owner_authenticator, so the consent screen
    # resolves the user exactly as every other page does (session lifetime
    # included) rather than reading session[:user_id] raw:
    #
    #   resource_owner_authenticator { RailsMcp::Authentication.resource_owner(self) }
    def self.resource_owner(controller)
      user = controller.send(:current_user)
      return user if user

      controller.session[:return_to] = controller.request.fullpath
      controller.send(:redirect_to, RailsMcp.config.sign_in_path.call(controller.request),
                      alert: "Sign in to authorize this connection.")
      nil
    end

    def current_user
      return @current_user if defined?(@current_user)

      @current_user = resolve_session_user
    end

    def signed_in?
      current_user.present?
    end

    def require_sign_in
      return if signed_in?

      session[:return_to] = request.fullpath if request.get? || request.head?
      target = RailsMcp.config.sign_in_path.call(request)
      redirect_to target, alert: "Sign in to continue."
    end

    private

    def resolve_session_user
      user_id = session[:user_id]
      return nil if user_id.blank?

      if RailsMcp::Authentication.session_expired?(session)
        reset_session
        return nil
      end

      RailsMcp::User.find_by(id: user_id)
    end
  end
end
