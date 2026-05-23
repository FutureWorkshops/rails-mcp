module RailsMcp
  # CSRF-exempt base class that Doorkeeper's own controllers inherit from. Host
  # configures Doorkeeper with `base_controller "RailsMcp::OauthBaseController"`.
  class OauthBaseController < ::ApplicationController
    skip_before_action :verify_authenticity_token, raise: false
  end
end
