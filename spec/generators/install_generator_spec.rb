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
      end
    RUBY
    File.write(File.join(destination_root, "Gemfile"), %(source "https://rubygems.org"\n))

    run_generator [ "Gmail" ]
  end

  let(:dest) { destination_root }

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

  it "creates routes.rb mounting the engine + use_doorkeeper outside the engine namespace" do
    body = expect_file "config/routes.rb",
      "mount RailsMcp::Engine",
      "use_doorkeeper",
      'to: "gmail_oauth#connect"',
      'as: :gmail_connect'
    # Critical gotcha: use_doorkeeper must NOT be inside the engine mount.
    expect(body.index("use_doorkeeper")).to be > body.index("mount RailsMcp::Engine")
    expect_ruby_parses "config/routes.rb"
  end

  it "creates ApplicationController with engine concerns included" do
    expect_file "app/controllers/application_controller.rb",
      "include RailsMcp::Authentication",
      "include RailsMcp::OnboardingGate"
    expect_ruby_parses "app/controllers/application_controller.rb"
  end

  it "creates the host dashboard controllers" do
    %w[sessions_controller connections_controller tools_controller].each do |c|
      expect_file "app/controllers/#{c}.rb"
      expect_ruby_parses "app/controllers/#{c}.rb"
    end

    expect_file "app/controllers/connections_controller.rb",
      'type: "GmailConnection"',
      "require_sign_in",
      "require_onboarding"
  end

  it "creates the provider OAuth controller with reset_session in the callback" do
    body = expect_file "app/controllers/gmail_oauth_controller.rb",
      "class GmailOauthController",
      "AUTHORIZE_URL",
      "TOKEN_URL",
      "USERINFO_URL",
      "reset_session",
      "session[:user_id] = user.id",
      "RailsMcp::Invitation.consume_from_session!",
      "session[:gmail_oauth_state]"
    # reset_session MUST come before session[:user_id] (defeats session fixation).
    expect(body.index("reset_session")).to be < body.index("session[:user_id] = user.id")
    expect_ruby_parses "app/controllers/gmail_oauth_controller.rb"
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
    expect_file "app/mcp/gmail_tool.rb",
      "class GmailTool < RailsMcp::BaseTool",
      "GmailApiError",
      "raise_for_status"
    expect_ruby_parses "app/mcp/gmail_tool.rb"

    expect_file "app/mcp/registry.rb", "ALL_TOOLS"
    expect_ruby_parses "app/mcp/registry.rb"

    expect(File.exist?(File.join(dest, "app/mcp/tools/.keep"))).to be(true)
  end

  it "creates all initializers" do
    {
      "config/initializers/rails_mcp.rb"               => [ "RailsMcp.configure", 'c.server_name    = "gmail-mcp-rails"',
                                                            'c.display_name   = "Gmail MCP"', "Mcp::Registry::ALL_TOOLS",
                                                            'c.sign_in_path = ->(_request) { "/gmail/connect" }' ],
      "config/initializers/doorkeeper.rb"              => [ "Doorkeeper.configure", "RailsMcp.config.sign_in_path",
                                                            "RailsMcp::OauthBaseController", "pkce_code_challenge_methods" ],
      "config/initializers/rack_attack.rb"             => [ "RailsMcp::RackAttackDefaults.apply!", "allow /up" ],
      "config/initializers/exception_notification.rb"  => [ "RailsMcp::ExceptionNotifierDefaults.apply!",
                                                            'username:    "gmail-mcp"' ],
      "config/initializers/content_security_policy.rb" => [ "content_security_policy",
                                                            "policy.form_action :self," ],
      "config/initializers/app_config.rb"              => [ "module AppConfig",
                                                            "def self.gmail_client_id",
                                                            "def self.gmail_redirect_uri" ],
      "config/initializers/zeitwerk.rb"                => [ "module Mcp",
                                                            'mcp_dir = Rails.root.join("app/mcp")',
                                                            "Rails.autoloaders.main.push_dir(mcp_dir, namespace: Mcp)" ]
    }.each do |rel, snippets|
      expect_file(rel, *snippets)
      expect_ruby_parses(rel)
    end
  end

  it "creates the views" do
    %w[
      app/views/shared/_cowork_tokens.html.erb
      app/views/shared/_fw_logo.html.erb
      app/views/shared/_flash.html.erb
      app/views/layouts/application.html.erb
      app/views/sessions/new.html.erb
      app/views/connections/index.html.erb
      app/views/tools/index.html.erb
      app/views/doorkeeper/authorizations/new.html.erb
    ].each { |path| expect_file(path) }

    expect_file "app/views/layouts/application.html.erb", "Gmail MCP"
    expect_file "app/views/sessions/new.html.erb",        "Sign in with Gmail"
    expect_file "app/views/connections/index.html.erb",   "Gmail Account",
                                                          "main_app.gmail_connect_path"
    expect_file "app/views/doorkeeper/authorizations/new.html.erb",
                "Authorize <%= @pre_auth.client.name %>",
                "Gmail MCP account"
  end

  it "patches config/application.rb to add Rack::Attack middleware" do
    expect_file "config/application.rb",
      'require "rack/attack"',
      "config.middleware.use Rack::Attack"
  end

  it "patches config/environments/production.rb with HSTS, hosts, mailer" do
    expect_file "config/environments/production.rb",
      "config.assume_ssl = true",
      "config.force_ssl  = true",
      "hsts:",
      "preload: true",
      'ENV.fetch("APP_HOST")',
      "config.host_authorization"
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
