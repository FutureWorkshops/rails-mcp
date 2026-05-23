module RailsMcp
  module Authentication
    extend ActiveSupport::Concern

    included do
      helper_method :current_user, :signed_in?
    end

    def current_user
      @current_user ||= RailsMcp::User.find_by(id: session[:user_id]) if session[:user_id]
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
  end
end
