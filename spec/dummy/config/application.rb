require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)
require "rails_mcp"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.active_record.encryption.primary_key            = "test" * 8
    config.active_record.encryption.deterministic_key      = "tdet" * 8
    config.active_record.encryption.key_derivation_salt    = "tslt" * 8

    config.secret_key_base = "dummy_secret_key_base_for_engine_specs"
    config.action_mailer.delivery_method = :test
    config.action_mailer.default_url_options = { host: "test.host" }
    config.active_job.queue_adapter = :test

    config.session_store :cookie_store, key: "_dummy_session"
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore, key: config.session_options[:key]
  end
end
