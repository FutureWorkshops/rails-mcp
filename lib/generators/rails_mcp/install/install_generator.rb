require "rails/generators"

module RailsMcp
  module Generators
    # Scaffolds a new MCP server host on top of the rails_mcp engine. Run from
    # the host's project root, after the engine has been added to the host's
    # Gemfile pinned to a release tag (never a branch, see README ->
    # Versioning):
    #
    #   gem "rails_mcp", git: "https://github.com/FutureWorkshops/rails-mcp.git", tag: "v1.2.1"
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

      # Skips gems the Gemfile already lists, so running the generator again
      # (e.g. after a failed first run) doesn't add every line twice.
      def add_gems
        gem "doorkeeper",       "~> 5.8" unless gem_listed?("doorkeeper")
        gem "faraday",          "~> 2.9" unless gem_listed?("faraday")
        gem "faraday-retry"              unless gem_listed?("faraday-retry")

        return if gem_listed?("rspec-rails")

        gem_group :development, :test do
          gem "rspec-rails", "~> 8.0"
          gem "webmock"
        end
      end

      def copy_procfile
        copy_file "Procfile", "Procfile"
      end

      # Project instructions for Claude Code: the engine's conventions and
      # the security code a session must not weaken.
      def copy_claude_md
        template "CLAUDE.md.tt", "CLAUDE.md"
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

      def copy_groundwork_controller
        template "app/controllers/groundwork_oauth_controller.rb.tt",
                 "app/controllers/groundwork_oauth_controller.rb"
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
        # One class per file: Zeitwerk can't autoload the error class from
        # the tool base's file, and the tool error handler names it first.
        template "app/mcp/provider_api_error.rb.tt", "app/mcp/#{provider_slug}_api_error.rb"
        create_file "app/mcp/tools/.keep", ""
      end

      def copy_initializers
        template "config/initializers/rails_mcp.rb.tt",                "config/initializers/rails_mcp.rb"
        template "config/initializers/doorkeeper.rb.tt",               "config/initializers/doorkeeper.rb", force: true
        template "config/initializers/rack_attack.rb.tt",              "config/initializers/rack_attack.rb"
        template "config/initializers/content_security_policy.rb.tt",  "config/initializers/content_security_policy.rb", force: true
        template "config/initializers/app_config.rb.tt",               "config/initializers/app_config.rb"
        # Maps app/mcp/* to the Mcp:: namespace; without it the host's
        # Mcp::Registry / Mcp::*Tool constants are never autoloaded and every
        # request that resolves tools 500s with `uninitialized constant Mcp`.
        template "config/initializers/zeitwerk.rb.tt",                 "config/initializers/zeitwerk.rb"
      end

      def copy_views
        # Theme partials are verbatim copies (no ERB).
        copy_file "app/views/shared/_cowork_tokens.html.erb", "app/views/shared/_cowork_tokens.html.erb"
        copy_file "app/views/shared/_flash.html.erb",         "app/views/shared/_flash.html.erb"
        template  "app/views/shared/_lockup.html.erb.tt",     "app/views/shared/_lockup.html.erb"

        template "app/views/layouts/application.html.erb.tt", "app/views/layouts/application.html.erb", force: true
        template "app/views/sessions/new.html.erb.tt",        "app/views/sessions/new.html.erb"
        template "app/views/connections/index.html.erb.tt",   "app/views/connections/index.html.erb"
        template "app/views/tools/index.html.erb.tt",         "app/views/tools/index.html.erb"
        template "app/views/doorkeeper/authorizations/new.html.erb.tt",
                 "app/views/doorkeeper/authorizations/new.html.erb"
      end

      # Groundwork favicons, replacing the red-circle icons from `rails new`.
      def copy_icons
        %w[icon.svg icon.png groundwork-icon-32.png groundwork-apple-touch-icon.png].each do |icon|
          copy_file "public/#{icon}", "public/#{icon}", force: true
        end
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

          # No config.assume_ssl: Heroku's router sets X-Forwarded-Proto, so
          # Rails already knows which requests arrived over https. assume_ssl
          # tells Rails every request did, which turns force_ssl into a no-op
          # and leaves the app serving plain http.
          config.force_ssl  = true
          config.ssl_options = {
            hsts: { expires: 2.years, subdomains: true, preload: true },
            redirect: { exclude: ->(request) { request.path == "/up" } }
          }

          config.action_mailer.default_url_options = {
            host:     ENV.fetch("APP_HOST"),
            protocol: "https"
          }

          # Only the public host (plus explicit extras). A wildcard such as
          # *.herokuapp.com would let any app on that domain be used as the
          # Host, and the OAuth issuer is built from the request host.
          config.hosts = [
            ENV.fetch("APP_HOST")
          ] + ENV.fetch("EXTRA_ALLOWED_HOSTS", "").split(",").map(&:strip).reject(&:blank?)

          config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

          # --- end rails_mcp:install additions ---

        RUBY

        inject_into_file prod_path, block, after: "Rails.application.configure do\n"
      end

      # The daily usage report to Groundwork (RailsMcp::UsageReportJob).
      # `rails new` writes config/recurring.yml with a production section.
      def schedule_usage_report
        recurring = "config/recurring.yml"
        return unless destination_exist?(recurring)
        return if File.read(File.join(destination_root, recurring)).include?("RailsMcp::UsageReportJob")

        inject_into_file recurring, <<~YAML.indent(2), after: /^production:\n/
          rails_mcp_usage_report:
            class: RailsMcp::UsageReportJob
            schedule: every day at 2:30am
        YAML
      end

      # Hosts deploy to Heroku with one Postgres database (DATABASE_URL).
      # `rails new` sets production up with separate cache, queue and cable
      # databases, which Heroku doesn't provide, so point everything at the
      # primary database and create the Solid tables there by migration.
      def configure_single_database
        database_yml = "config/database.yml"
        if destination_exist?(database_yml)
          gsub_file database_yml, /^production:.*\z/m, <<~YAML
            production:
              <<: *default
              url: <%= ENV["DATABASE_URL"] %>
          YAML
        end

        gsub_file_if_exists "config/environments/production.rb", /^\s*config\.solid_queue\.connects_to = .*\n/, ""
        gsub_file_if_exists "config/cache.yml", /^  database: cache\n/, ""
        gsub_file_if_exists "config/cable.yml", /^  connects_to:\n    database:\n      writing: cable\n/, ""

        %w[cache queue cable].each { |name| remove_file "db/#{name}_schema.rb" }
        %w[
          20260523200001_create_solid_cache_tables.rb
          20260523200002_create_solid_queue_tables.rb
          20260523200003_create_solid_cable_tables.rb
        ].each { |migration| copy_file "db/migrate/#{migration}", "db/migrate/#{migration}" }
      end

      # RSpec with WebMock and spec/support loaded, run by bin/ci and by
      # GitHub Actions. Tools are tested against stubbed APIs, never live.
      def set_up_specs
        copy_file "rspec_options",          ".rspec",                skip: true
        copy_file "spec/spec_helper.rb",    "spec/spec_helper.rb",   skip: true
        copy_file "spec/rails_helper.rb",   "spec/rails_helper.rb",  skip: true
        create_file "spec/support/.keep", "", skip: true

        if destination_exist?("config/ci.rb") && !destination_read("config/ci.rb").include?("rspec")
          inject_into_file "config/ci.rb", <<~RUBY.indent(2), before: /^  step "Security: Gem audit"/
            step "Tests: RSpec", "bin/rails db:test:prepare && bundle exec rspec"

          RUBY
        end

        workflow = ".github/workflows/ci.yml"
        if destination_exist?(workflow) && !destination_read(workflow).match?(/^  test:$/)
          append_to_file workflow, "\n" + File.read(File.join(self.class.source_root, "github/ci_test_job.yml"))
        end

        # Specs and CI run without the master key, so the test environment
        # gets fixed, throwaway Active Record encryption keys.
        test_rb = "config/environments/test.rb"
        if destination_exist?(test_rb) && !destination_read(test_rb).include?("active_record.encryption")
          inject_into_file test_rb, <<~RUBY.indent(2), after: "Rails.application.configure do\n"
            # Fixed, test-only Active Record encryption keys, so specs and CI run
            # without the master key. Real keys live in the credentials file.
            config.active_record.encryption.primary_key = "test-primary-key-not-a-secret-0000"
            config.active_record.encryption.deterministic_key = "test-deterministic-key-not-a-secret"
            config.active_record.encryption.key_derivation_salt = "test-key-derivation-salt-not-a-secret"

          RUBY
        end
      end

      # The engine encrypts stored provider tokens, so production needs
      # Active Record encryption keys. Adds fresh ones to the host's
      # credentials (never printed) when the master key is present and the
      # generator is running inside that host.
      def add_encryption_keys
        return unless defined?(Rails.application) && Rails.application
        return unless File.expand_path(destination_root) == File.expand_path(Rails.root.to_s)

        credentials = Rails.application.credentials
        return say_status(:skip, "no master key: run bin/rails db:encryption:init and add the keys to credentials", :yellow) if credentials.key.nil?

        content = credentials.read
        return if content.include?("active_record_encryption:")

        credentials.write(content.rstrip + "\n\nactive_record_encryption:\n" +
          %w[primary_key deterministic_key key_derivation_salt].map { |k| "  #{k}: #{SecureRandom.alphanumeric(32)}\n" }.join)
        say_status :credentials, "added active_record_encryption keys", :green
      end

      def show_next_steps
        say "\n#{'=' * 72}", :green
        say "rails_mcp:install complete for provider: #{provider_const}", :green
        say "=" * 72, :green
        say <<~NEXT

          Next steps the generator can't do for you:

            0. Check the rails_mcp line in your Gemfile is pinned to a release
               tag (tag: "vX.Y.Z"), not branch: "main". See the engine README
               -> Versioning.

            1. Fill in OAuth URLs in app/controllers/#{provider_slug}_oauth_controller.rb
               (AUTHORIZE_URL, TOKEN_URL, USERINFO_URL, scope string).

            2. Set API_BASE + TOKEN_URL in app/services/#{provider_slug}_client_service.rb.

            3. bin/rails credentials:edit
               Add a `#{provider_slug}:` block with client_id / client_secret /
               redirect_uri / contact_email, and a `groundwork:` block with the
               client_id / client_secret of this host's OAuth client in
               Groundwork (redirect URI https://<APP_HOST>/groundwork/callback).

            4. Write your tools under app/mcp/tools/ and list them in
               app/mcp/registry.rb.

            5. (Optional) bin/rails g migration Add#{provider_const}ColumnsToConnections
               Add provider-specific columns if needed (e.g. tenant_id, workspace_name).

            6. bin/rails db:create db:migrate

            7. bin/rails server  →  visit /sign_in, complete the OAuth dance,
               smoke test from Claude Desktop at https://<APP_HOST>/mcp.

            8. (Recommended) Wire up error monitoring. Add `gem "sentry-rails"`
               and configure it per the Sentry Rails docs — see
               BUILDING_A_HOST.md in the engine repo → Error monitoring.

            9. Heroku deploy — see BUILDING_A_HOST.md in the engine repo →
               Heroku deploy.

        NEXT
      end

      private

      def gem_listed?(name)
        gemfile = File.join(destination_root, "Gemfile")
        File.exist?(gemfile) && File.read(gemfile).match?(/^\s*gem\s+["']#{Regexp.escape(name)}["']/)
      end

      def destination_exist?(path)
        File.exist?(File.join(destination_root, path))
      end

      def destination_read(path)
        File.read(File.join(destination_root, path))
      end

      def gsub_file_if_exists(path, pattern, replacement)
        gsub_file(path, pattern, replacement) if destination_exist?(path)
      end
    end
  end
end
