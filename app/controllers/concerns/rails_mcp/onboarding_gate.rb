module RailsMcp
  module OnboardingGate
    extend ActiveSupport::Concern

    def require_onboarding
      return unless signed_in?
      return if current_user.account.onboarded?

      redirect_to RailsMcp::Engine.routes.url_helpers.onboarding_path
    end
  end
end
