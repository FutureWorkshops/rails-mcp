require "rails_helper"
require "rails/generators"
require "rails/generators/testing/behavior"
require "fileutils"
require "generators/rails_mcp/install/install_generator"

RSpec.describe RailsMcp::Generators::InstallGenerator, type: :generator do
  include FileUtils
  include Rails::Generators::Testing::Behavior

  destination File.expand_path("../../tmp/install_generator", __dir__)
  tests RailsMcp::Generators::InstallGenerator

  before do
    prepare_destination

    # Pretend we're inside a freshly-generated Rails app — the patch_* steps
    # look for these two files and inject into them.
    FileUtils.mkdir_p(File.join(destination_root, "config", "environments"))
    File.write(File.join(destination_root, "config", "application.rb"), <<~RUBY)
      require_relative "boot"
      require "rails/all"

      module Dummy
        class Application < Rails::Application
          config.load_defaults 8.1
        end
      end
    RUBY
    File.write(File.join(destination_root, "config", "environments", "production.rb"), <<~RUBY)
      Rails.application.configure do
        config.cache_classes = true
        config.active_job.queue_adapter = :solid_queue
        config.solid_queue.connects_to = { database: { writing: :queue } }
      end
    RUBY
    File.write(File.join(destination_root, "config", "environments", "test.rb"), "Rails.application.configure do\nend\n")
    File.write(File.join(destination_root, "Gemfile"), %(source "https://rubygems.org"\n))

    # The multi-database production setup `rails new -d=postgresql` writes.
    File.write(File.join(destination_root, "config", "database.yml"), <<~YAML)
      default: &default
        adapter: postgresql
      development:
        <<: *default
        database: dummy_development
      production:
        primary: &primary_production
          <<: *default
          database: dummy_production
        cache:
          <<: *primary_production
          database: dummy_production_cache
          migrations_paths: db/cache_migrate
    YAML
    File.write(File.join(destination_root, "config", "cache.yml"), "default: &default\n  store_options: {}\n\nproduction:\n  database: cache\n  <<: *default\n")
    File.write(File.join(destination_root, "config", "cable.yml"),
               "production:\n  adapter: solid_cable\n  connects_to:\n    database:\n      writing: cable\n  polling_interval: 0.1.seconds\n")
    File.write(File.join(destination_root, "config", "ci.rb"),
               %(CI.run do\n  step "Style: Ruby", "bin/rubocop"\n\n  step "Security: Gem audit", "bin/bundler-audit"\nend\n))
    FileUtils.mkdir_p(File.join(destination_root, ".github", "workflows"))
    File.write(File.join(destination_root, ".github", "workflows", "ci.yml"), "name: CI\n\njobs:\n  lint:\n    runs-on: ubuntu-latest\n")
    FileUtils.mkdir_p(File.join(destination_root, "db"))
    File.write(File.join(destination_root, "db", "queue_schema.rb"), "# queue schema\n")
    File.write(File.join(destination_root, "config", "recurring.yml"),
               "production:\n  clear_solid_queue_finished_jobs:\n    command: \"SolidQueue::Job.clear_finished_in_batches\"\n    schedule: every hour at minute 12\n")

    run_generator [ "Gmail" ]
  end

  let(:dest) { destination_root }

  it "schedules the daily usage report once, and wires the reporter" do
    run_generator [ "Gmail" ]

    recurring = File.read(File.join(dest, "config/recurring.yml"))
    expect(recurring.scan("class: RailsMcp::UsageReportJob").size).to eq(1)
    expect(YAML.safe_load(recurring).dig("production", "rails_mcp_usage_report", "schedule")).to eq("every day at 2:30am")
    expect(File.read(File.join(dest, "config/initializers/rails_mcp.rb")))
      .to include("c.usage_reporter = -> { GroundworkOauthController.report_usage }")
  end

  def expect_file(rel_path, *contents)
    full = File.join(dest, rel_path)
    expect(File.exist?(full)).to be(true), "expected #{rel_path} to exist"
    body = File.read(full)
    contents.each { |needle| expect(body).to include(needle), "expected #{rel_path} to include #{needle.inspect}" }
    body
  end

  def expect_ruby_parses(rel_path)
    body = File.read(File.join(dest, rel_path))
    expect { RubyVM::AbstractSyntaxTree.parse(body) }.not_to raise_error,
      "expected #{rel_path} to be syntactically valid Ruby"
  end

  it "creates Procfile" do
    expect_file "Procfile", "release: bin/rails db:migrate", "bin/rails server"
  end

  it "creates CLAUDE.md with the engine's conventions for Claude Code" do
    body = expect_file "CLAUDE.md",
      "# Gmail MCP",
      "app/mcp/tools/*_tool.rb",
      "Mcp::GmailTool",
      "app/services/gmail_client_service.rb",
      "kebab-case, verb-first",
      "Pin the engine by tag",
      "config.assume_ssl",
      "OAUTH_DCR_ALLOWED_REDIRECT_HOSTS"
    expect(body).not_to include("<%=")
  end

  it "creates routes.rb mounting the engine + use_doorkeeper outside the engine namespace" do
    body = expect_file "config/routes.rb",
      "mount RailsMcp::Engine",
      "use_doorkeeper",
      'to: "gmail_oauth#connect"',
      'as: :gmail_connect',
      'to: "groundwork_oauth#connect"',
      'as: :groundwork_connect'
    # Critical gotcha: use_doorkeeper must NOT be inside the engine mount.
    expect(body.index("use_doorkeeper")).to be > body.index("mount RailsMcp::Engine")
    expect_ruby_parses "config/routes.rb"
  end

  it "creates ApplicationController with engine concerns included" do
    body = expect_file "app/controllers/application_controller.rb",
      "include RailsMcp::Authentication"
    expect(body).not_to include("OnboardingGate")
    expect_ruby_parses "app/controllers/application_controller.rb"
  end

  it "creates the host dashboard controllers" do
    %w[sessions_controller connections_controller tools_controller].each do |c|
      expect_file "app/controllers/#{c}.rb"
      expect_ruby_parses "app/controllers/#{c}.rb"
    end

    expect_file "app/controllers/connections_controller.rb",
      'type: "GmailConnection"',
      "require_sign_in"
    expect(File.read(File.join(destination_root, "app/controllers/connections_controller.rb"))).not_to include("require_onboarding")
  end

  it "creates the provider OAuth controller as a connection-only flow (no identity)" do
    body = expect_file "app/controllers/gmail_oauth_controller.rb",
      "class GmailOauthController",
      "before_action :require_sign_in",
      "AUTHORIZE_URL",
      "TOKEN_URL",
      "USERINFO_URL",
      "upsert_connection",
      "session[:gmail_oauth_state]"
    # Identity is owned by GroundworkOauthController. The provider controller
    # must NOT create users or rotate sessions.
    expect(body).not_to include("reset_session")
    expect(body).not_to include("session[:user_id] = user.id")
    expect(body).not_to include("upsert_user")
    expect_ruby_parses "app/controllers/gmail_oauth_controller.rb"
  end

  it "creates the Groundwork SSO controller as a thin subclass of the engine base" do
    expect_file "app/controllers/groundwork_oauth_controller.rb",
      "class GroundworkOauthController < RailsMcp::OauthClientController",
      "AppConfig.groundwork_base_url",
      "AppConfig.groundwork_client_id",
      "AppConfig.groundwork_client_secret",
      "AppConfig.groundwork_redirect_uri",
      ":groundwork_oauth_state"
    expect_ruby_parses "app/controllers/groundwork_oauth_controller.rb"
    expect(File.exist?(File.join(dest, "app/controllers/cowork_hub_oauth_controller.rb"))).to be(false)
  end

  it "creates the connection STI subclass" do
    expect_file "app/models/gmail_connection.rb",
      "class GmailConnection < RailsMcp::Connection"
    expect_ruby_parses "app/models/gmail_connection.rb"
  end

  it "creates the API client service with Faraday timeouts + with_lock refresh" do
    expect_file "app/services/gmail_client_service.rb",
      "class GmailClientService",
      "OPEN_TIMEOUT",
      "READ_TIMEOUT",
      "WRITE_TIMEOUT",
      "with_lock",
      "ReconnectRequired",
      "mark_refresh_succeeded!",
      "mark_refresh_failed!"
    expect_ruby_parses "app/services/gmail_client_service.rb"
  end

  it "creates the host tool base class + registry + tools dir" do
    tool = expect_file "app/mcp/gmail_tool.rb",
      "class GmailTool < RailsMcp::BaseTool",
      "Mcp::GmailApiError.new",
      "raise_for_status"
    expect_ruby_parses "app/mcp/gmail_tool.rb"
    # Zeitwerk loads Mcp::GmailApiError from its own file, not the tool's.
    expect(tool).not_to include("class GmailApiError")
    expect_file "app/mcp/gmail_api_error.rb", "module Mcp", "class GmailApiError < StandardError"
    expect_ruby_parses "app/mcp/gmail_api_error.rb"

    expect_file "app/mcp/registry.rb", "ALL_TOOLS"
    expect_ruby_parses "app/mcp/registry.rb"

    expect(File.exist?(File.join(dest, "app/mcp/tools/.keep"))).to be(true)
  end

  it "creates all initializers" do
    {
      "config/initializers/rails_mcp.rb"               => [ "RailsMcp.configure", 'c.server_name    = "gmail-mcp-rails"',
                                                            'c.display_name   = "Gmail MCP"', "Mcp::Registry::ALL_TOOLS",
                                                            'c.sign_in_path = ->(_request) { "/groundwork/connect" }',
                                                            "c.identity_status = ->(user) { GroundworkOauthController.identity_status(user) }",
                                                            "c.on_user_deactivated = ->(user) { user.connections.destroy_all }" ],
      "config/initializers/doorkeeper.rb"              => [ "Doorkeeper.configure",
                                                            "resource_owner_authenticator { RailsMcp::Authentication.resource_owner(self) }",
                                                            "access_token_methods :from_bearer_authorization",
                                                            "RailsMcp::RedirectUris.force_ssl?(uri)",
                                                            "RailsMcp::OauthBaseController", "pkce_code_challenge_methods",
                                                            "force_pkce", "  hash_token_secrets\n" ],
      "config/initializers/rack_attack.rb"             => [ "RailsMcp::RackAttackDefaults.apply!", "allow /up" ],
      "config/initializers/content_security_policy.rb" => [ "content_security_policy",
                                                            "policy.form_action :self,",
                                                            "policy.script_src  :self\n",
                                                            "SecureRandom.base64(16)" ],
      "config/initializers/app_config.rb"              => [ "module AppConfig",
                                                            "def self.gmail_client_id",
                                                            "def self.gmail_redirect_uri",
                                                            "credentials.dig(:gmail, :client_id)",
                                                            "def self.groundwork_client_id",
                                                            "def self.groundwork_redirect_uri",
                                                            '"https://groundwork.fws.io"' ],
      "config/initializers/zeitwerk.rb"                => [ "module Mcp",
                                                            'mcp_dir = Rails.root.join("app/mcp")',
                                                            "Rails.autoloaders.main.push_dir(mcp_dir, namespace: Mcp)" ]
    }.each do |rel, snippets|
      expect_file(rel, *snippets)
      expect_ruby_parses(rel)
    end
  end

  it "replaces the rails new favicons with the Groundwork ones" do
    %w[public/icon.svg public/icon.png public/groundwork-icon-32.png public/groundwork-apple-touch-icon.png]
      .each { |path| expect(File).to exist(File.join(destination_root, path)) }
    expect_file "public/icon.svg", "#1F4BD8"
  end

  it "creates the views" do
    %w[
      app/views/shared/_cowork_tokens.html.erb
      app/views/shared/_lockup.html.erb
      app/views/shared/_flash.html.erb
      app/views/layouts/application.html.erb
      app/views/sessions/new.html.erb
      app/views/connections/index.html.erb
      app/views/tools/index.html.erb
      app/views/doorkeeper/authorizations/new.html.erb
    ].each { |path| expect_file(path) }

    expect_file "app/views/layouts/application.html.erb", "Groundwork Gmail MCP", 'render "shared/lockup"'
    expect_file "app/views/shared/_lockup.html.erb",      "Groundwork", "Gmail MCP"
    expect_file "app/views/shared/_cowork_tokens.html.erb", "--cw-accent: #1f4bd8"
    expect(File).not_to exist(File.join(destination_root, "app/views/shared/_fw_logo.html.erb"))
    expect_file "app/views/sessions/new.html.erb",        "Sign in with Groundwork",
                                                          "main_app.groundwork_connect_path"
    expect_file "app/views/connections/index.html.erb",   "Gmail Account",
                                                          "main_app.gmail_connect_path"
    expect_file "app/views/doorkeeper/authorizations/new.html.erb",
                "Authorize <%= @pre_auth.client.name %>",
                "your connected Gmail accounts"
  end

  it "patches config/application.rb to add Rack::Attack middleware" do
    body = expect_file "config/application.rb",
      'require "rack/attack"',
      "config.middleware.use Rack::Attack"
    # No blank line opening the class body (rubocop's Layout/EmptyLinesAroundClassBody).
    expect(body).not_to include("class Application < Rails::Application\n\n")
  end

  it "points production at the one Heroku database and creates the Solid tables by migration" do
    database = expect_file "config/database.yml", "production:\n  <<: *default\n  url: <%= ENV[\"DATABASE_URL\"] %>"
    expect(database).not_to include("dummy_production_cache")
    expect(database).to include("dummy_development")
    expect(File.read(File.join(dest, "config/environments/production.rb"))).not_to include("solid_queue.connects_to")
    expect(File.read(File.join(dest, "config/cache.yml"))).not_to include("database: cache")
    expect(File.read(File.join(dest, "config/cable.yml"))).not_to include("connects_to")
    expect(File.exist?(File.join(dest, "db/queue_schema.rb"))).to be(false)
    %w[cache queue cable].each_with_index do |name, i|
      path = "db/migrate/2026052320000#{i + 1}_create_solid_#{name}_tables.rb"
      expect_file path, "class CreateSolid#{name.capitalize}Tables"
      expect_ruby_parses path
    end
  end

  it "sets up RSpec with WebMock, run by bin/ci and GitHub Actions without the master key" do
    expect_file ".rspec", "--require spec_helper"
    expect_file "spec/rails_helper.rb", "require 'webmock/rspec'", "WebMock.disable_net_connect!",
                "Rails.root.glob('spec/support/**/*.rb')", "ActiveSupport::Testing::TimeHelpers"
    expect_file "config/ci.rb", %(step "Tests: RSpec", "bin/rails db:test:prepare && bundle exec rspec")
    ci = File.read(File.join(dest, "config/ci.rb"))
    expect(ci.index("Tests: RSpec")).to be < ci.index("Security: Gem audit")
    expect_file ".github/workflows/ci.yml", "  test:", "image: postgres", "bundle exec rspec"
    expect_file "config/environments/test.rb", "config.active_record.encryption.primary_key"
  end

  it "doesn't add gems twice when run again" do
    run_generator [ "Gmail" ]

    gemfile = File.read(File.join(dest, "Gemfile"))
    %w[doorkeeper faraday faraday-retry rspec-rails webmock].each do |name|
      expect(gemfile.scan(/^\s*gem "#{name}"/).size).to eq(1), "expected #{name} once in the Gemfile"
    end
    expect(File.read(File.join(dest, "config/ci.rb")).scan("Tests: RSpec").size).to eq(1)
    expect(File.read(File.join(dest, ".github/workflows/ci.yml")).scan(/^  test:$/).size).to eq(1)
  end

  it "patches config/environments/production.rb with HSTS, hosts, mailer" do
    expect_file "config/environments/production.rb",
      "config.force_ssl  = true",
      "hsts:",
      "preload: true",
      'ENV.fetch("APP_HOST")',
      "config.host_authorization"
    expect(File.read(File.join(destination_root, "config/environments/production.rb"))).not_to include('/.*\\.herokuapp')
    expect(File.read(File.join(destination_root, "config/environments/production.rb"))).not_to include("configure do\n\n")
    expect(File.read(File.join(destination_root, "config/initializers/doorkeeper.rb"))).not_to include("fallback: :plain")
  end

  # assume_ssl makes every request look like https, so force_ssl never
  # redirects and the app serves plain http behind Heroku's router.
  it "does not set assume_ssl, which would turn force_ssl into a no-op" do
    body = File.read(File.join(destination_root, "config/environments/production.rb"))
    expect(body).not_to match(/^\s*config\.assume_ssl/)
    expect(body).to include("config.force_ssl  = true", 'redirect: { exclude: ->(request) { request.path == "/up" } }')
  end

  it "does not read session[:user_id] raw in the Doorkeeper authenticator" do
    expect(File.read(File.join(destination_root, "config/initializers/doorkeeper.rb"))).not_to include("find_by(id: session[:user_id])")
  end

  describe "with a snake_cased provider argument" do
    before do
      prepare_destination
      FileUtils.mkdir_p(File.join(destination_root, "config", "environments"))
      File.write(File.join(destination_root, "Gemfile"), %(source "https://rubygems.org"\n))
      File.write(File.join(destination_root, "config", "application.rb"),
                 "module Dummy\nclass Application < Rails::Application\nend\nend\n")
      File.write(File.join(destination_root, "config", "environments", "production.rb"),
                 "Rails.application.configure do\nend\n")
      run_generator [ "github_api" ]
    end

    it "normalises to CamelCase for class names and snake_case for file paths" do
      expect_file "app/controllers/github_api_oauth_controller.rb",
        "class GithubApiOauthController",
        "session[:github_api_oauth_state]"
      expect_file "app/models/github_api_connection.rb",
        "class GithubApiConnection < RailsMcp::Connection"
    end
  end
end
