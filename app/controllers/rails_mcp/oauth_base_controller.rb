module RailsMcp
  # CSRF-exempt base class that Doorkeeper's own controllers inherit from. Host
  # configures Doorkeeper with `base_controller "RailsMcp::OauthBaseController"`.
  #
  # Forces the host's application layout so the OAuth consent screen renders
  # with the host's chrome (nav, logo, design tokens). Without this Doorkeeper
  # falls back to its own near-empty "doorkeeper/application" layout and every
  # host's customised view appears unstyled.
  class OauthBaseController < ::ApplicationController
    layout "application"

    skip_before_action :verify_authenticity_token, raise: false
  end
end
