module RailsMcp
  # Validates the OAuth `state` round-trip for authorization-code callbacks.
  #
  # Both values must be present: comparing with `!=` alone lets a callback with
  # no `state` through whenever the session holds no pending state (nil == nil),
  # which is the normal case for a visitor who never started the flow. That is
  # a login / account-linking CSRF: an attacker can make a victim's browser
  # complete *their* authorization code.
  module OauthState
    module_function

    def valid?(expected, received)
      expected.present? && received.present? &&
        ActiveSupport::SecurityUtils.secure_compare(expected.to_s, received.to_s)
    end
  end
end
