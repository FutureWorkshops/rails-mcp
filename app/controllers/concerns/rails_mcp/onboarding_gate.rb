module RailsMcp
  # Deprecated: the workspace-naming onboarding step was removed (accounts are
  # mirrored from the identity provider). Kept as a no-op so hosts that still
  # `include RailsMcp::OnboardingGate` and `before_action :require_onboarding`
  # keep working; remove both from the host, then this module can go.
  module OnboardingGate
    extend ActiveSupport::Concern

    def require_onboarding; end
  end
end
