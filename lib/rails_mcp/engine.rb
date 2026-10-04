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

    # Make engine migrations runnable straight from the gem via the host's
    # `bin/rails db:migrate`. Hosts must NOT run `rails_mcp:install:migrations`:
    # copying the migrations into the host's db/migrate would double-run them
    # (once from the gem, once from the copy) and leave the host owning files it
    # has to hand-sync on every engine bump. See README → Migrations.
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

    # MCP tool arguments carry user content (email bodies, event descriptions,
    # invoices). POST /mcp is JSON, so Rails would log them in full on every
    # call; filter the whole arguments hash.
    MCP_FILTER_PARAMETERS = %i[arguments].freeze

    # Refresh-token policy (idle expiry, leaver check, reuse detection) on
    # every refresh_token grant. See RailsMcp::RefreshTokenPolicy.
    config.to_prepare do
      require "rails_mcp/refresh_token_policy"
      request_class = Doorkeeper::OAuth::RefreshTokenRequest
      hooks = RailsMcp::RefreshTokenPolicy::RequestHooks
      request_class.prepend(hooks) unless request_class.ancestors.include?(hooks)
    end

    initializer :append_filter_parameters, before: :load_config_initializers do |app|
      app.config.filter_parameters += OAUTH_FILTER_PARAMETERS + MCP_FILTER_PARAMETERS
    end
  end
end
