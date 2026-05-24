require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "doorkeeper"

module RailsMcp
  class Engine < ::Rails::Engine
    isolate_namespace RailsMcp

    config.generators do |g|
      g.test_framework :rspec
      g.orm :active_record
    end

    # Make engine migrations runnable from the host without requiring the
    # standard `rails_mcp:install:migrations` copy step. Host apps can still
    # opt into copying if they prefer migrations live in db/migrate locally.
    initializer :append_migrations do |app|
      next if app.root.to_s == root.to_s
      config.paths["db/migrate"].expanded.each do |path|
        app.config.paths["db/migrate"] << path
      end
    end

    # OAuth secrets that must never appear in Rails logs. Appending here means
    # every host that mounts the engine gets the same defensive filter list
    # without needing to remember to add these keys to its own
    # filter_parameter_logging initializer.
    OAUTH_FILTER_PARAMETERS = %i[
      access_token refresh_token client_secret authorization bearer code
    ].freeze

    initializer :append_filter_parameters, before: :load_config_initializers do |app|
      app.config.filter_parameters += OAUTH_FILTER_PARAMETERS
    end
  end
end
