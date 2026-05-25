require "rails/generators"

module RailsMcp
  module Generators
    # Scaffolds a new MCP server host on top of the rails_mcp engine. Run from
    # the host's project root, after the engine has been added to the host's
    # Gemfile:
    #
    #   bin/rails generate rails_mcp:install <Provider>
    #
    # `<Provider>` is the identity-provider / API the host integrates with.
    # CamelCase, snake_case and SHOUTY-SNAKE all accepted (`Gmail`, `gmail`,
    # `GITHUB`). The generator writes ~28 files into the host: controllers,
    # views, models, services, the MCP framework, initializers, routes,
    # Procfile, and patches to application.rb / production.rb. After running,
    # the runner has to fill in OAuth URLs + API base + tools + credentials.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Scaffold a new MCP server host using the rails_mcp engine."

      argument :provider_name,
               type: :string,
               banner: "Provider"

      # ---------- name accessors used inside templates ----------

      def provider_const
        provider_name.gsub(/[^A-Za-z0-9]+/, "_").camelize
      end

      def provider_slug
        provider_const.underscore
      end

      def provider_human
        provider_const.titleize
      end

      def provider_connect_path
        "/#{provider_slug.tr('_', '-')}/connect"
      end

      def provider_callback_path
        "/#{provider_slug.tr('_', '-')}/callback"
      end

      def provider_disconnect_path
        "/#{provider_slug.tr('_', '-')}/accounts/:external_id"
      end

      def session_state_key
        "#{provider_slug}_oauth_state"
      end

      # ---------- generator steps (Thor calls each in order) ----------

      def add_gems
        gem "doorkeeper",       "~> 5.8"
        gem "faraday",          "~> 2.9"
        gem "faraday-retry"

        gem_group :development, :test do
          gem "rspec-rails", "~> 8.0"
          gem "webmock"
        end

        say "\n  Optional: add `gem \"exception_notification\"` + `gem \"slack-notifier\"`",
            :yellow
        say "  to your Gemfile to enable the Slack error reporter (initializer is already wired).", :yellow
      end

      def copy_procfile
        copy_file "Procfile", "Procfile"
      end

      def copy_routes
        template "routes.rb.tt", "config/routes.rb", force: true
      end

      def copy_application_controller
        template "app/controllers/application_controller.rb.tt",
                 "app/controllers/application_controller.rb",
                 force: true
      end

      def copy_host_controllers
        template "app/controllers/sessions_controller.rb.tt",    "app/controllers/sessions_controller.rb"
        template "app/controllers/connections_controller.rb.tt", "app/controllers/connections_controller.rb"
        template "app/controllers/tools_controller.rb.tt",       "app/controllers/tools_controller.rb"
      end

      def copy_oauth_controller
        template "app/controllers/provider_oauth_controller.rb.tt",
                 "app/controllers/#{provider_slug}_oauth_controller.rb"
      end

      def copy_models
        template "app/models/provider_connection.rb.tt",
                 "app/models/#{provider_slug}_connection.rb"
      end

      def copy_service
        template "app/services/provider_client_service.rb.tt",
                 "app/services/#{provider_slug}_client_service.rb"
      end

      def copy_mcp_layer
        template "app/mcp/provider_tool.rb.tt", "app/mcp/#{provider_slug}_tool.rb"
        template "app/mcp/registry.rb.tt",      "app/mcp/registry.rb"
        create_file "app/mcp/tools/.keep", ""
      end

      def copy_initializers
        template "config/initializers/rails_mcp.rb.tt",                "config/initializers/rails_mcp.rb"
        template "config/initializers/doorkeeper.rb.tt",               "config/initializers/doorkeeper.rb", force: true
        template "config/initializers/rack_attack.rb.tt",              "config/initializers/rack_attack.rb"
        template "config/initializers/exception_notification.rb.tt",   "config/initializers/exception_notification.rb"
        template "config/initializers/content_security_policy.rb.tt",  "config/initializers/content_security_policy.rb", force: true
        template "config/initializers/app_config.rb.tt",               "config/initializers/app_config.rb"
      end

      def copy_views
        # Theme partials are verbatim copies (no ERB).
        copy_file "app/views/shared/_cowork_tokens.html.erb", "app/views/shared/_cowork_tokens.html.erb"
        copy_file "app/views/shared/_fw_logo.html.erb",       "app/views/shared/_fw_logo.html.erb"
        copy_file "app/views/shared/_flash.html.erb",         "app/views/shared/_flash.html.erb"

        template "app/views/layouts/application.html.erb.tt", "app/views/layouts/application.html.erb", force: true
        template "app/views/sessions/new.html.erb.tt",        "app/views/sessions/new.html.erb"
        template "app/views/connections/index.html.erb.tt",   "app/views/connections/index.html.erb"
        template "app/views/tools/index.html.erb.tt",         "app/views/tools/index.html.erb"
        template "app/views/doorkeeper/authorizations/new.html.erb.tt",
                 "app/views/doorkeeper/authorizations/new.html.erb"
      end

      def patch_application_rb
        application_path = "config/application.rb"
        return unless File.exist?(File.join(destination_root, application_path))

        inject_into_class application_path, "Application", <<~RUBY.indent(4)

          # Rate limiting via Rack::Attack (engine ships RailsMcp::RackAttackDefaults).
          require "rack/attack"
          config.middleware.use Rack::Attack
        RUBY
      end

      def patch_production_rb
        prod_path = "config/environments/production.rb"
        return unless File.exist?(File.join(destination_root, prod_path))

        block = <<~RUBY.indent(2)

          # --- rails_mcp:install additions ---

          config.assume_ssl = true
          config.force_ssl  = true
          config.ssl_options = {
            hsts: { expires: 2.years, subdomains: true, preload: true },
            redirect: { exclude: ->(request) { request.path == "/up" } }
          }

          config.action_mailer.default_url_options = {
            host:     ENV.fetch("APP_HOST"),
            protocol: "https"
          }

          config.hosts = [
            ENV.fetch("APP_HOST"),
            /.*\\.herokuapp\\.com/
          ] + ENV.fetch("EXTRA_ALLOWED_HOSTS", "").split(",").map(&:strip).reject(&:blank?)

          config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

          # --- end rails_mcp:install additions ---
        RUBY

        inject_into_file prod_path, block, after: "Rails.application.configure do\n"
      end

      def show_next_steps
        say "\n#{'=' * 72}", :green
        say "rails_mcp:install complete for provider: #{provider_const}", :green
        say "=" * 72, :green
        say <<~NEXT

          Next steps the generator can't do for you:

            1. Fill in OAuth URLs in app/controllers/#{provider_slug}_oauth_controller.rb
               (AUTHORIZE_URL, TOKEN_URL, USERINFO_URL, scope string).

            2. Set API_BASE + TOKEN_URL in app/services/#{provider_slug}_client_service.rb.

            3. bin/rails credentials:edit
               Add a `#{provider_slug}:` block with client_id / client_secret /
               redirect_uri / contact_email.

            4. Write your tools under app/mcp/tools/ and list them in
               app/mcp/registry.rb.

            5. (Optional) bin/rails g migration Add#{provider_const}ColumnsToConnections
               Add provider-specific columns if needed (e.g. tenant_id, workspace_name).

            6. bin/rails db:create db:migrate

            7. bin/rails server  →  visit /sign_in, complete the OAuth dance,
               smoke test from Claude Desktop at https://<APP_HOST>/mcp.

            8. Heroku deploy — see engines/rails_mcp/BUILDING_A_HOST.md → Deploy.

        NEXT
      end
    end
  end
end
