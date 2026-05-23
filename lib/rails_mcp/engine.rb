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
  end
end
