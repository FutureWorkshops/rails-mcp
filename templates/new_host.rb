# Rails application template for a new MCP server on the rails_mcp engine.
# Creates the app, pins the engine to a release tag and runs
# `rails_mcp:install`, which also writes a CLAUDE.md for Claude Code.
#
#   rails new gmail-mcp-rails -d=postgresql --skip-jbuilder \
#     -m https://raw.githubusercontent.com/FutureWorkshops/rails-mcp/main/templates/new_host.rb
#
# The provider defaults to the app name without "-mcp-rails" (gmail-mcp-rails
# -> Gmail). Override without a prompt via PROVIDER=XeroPayroll, and the
# engine tag via RAILS_MCP_TAG=v1.2.0. Engine developers can try an unreleased
# engine with RAILS_MCP_PATH=~/Development/rails-mcp (never commit that).

# Bumped by each release PR, alongside RailsMcp::VERSION.
RAILS_MCP_TAG = "v1.2.0"

tag = ENV.fetch("RAILS_MCP_TAG", RAILS_MCP_TAG)
unless tag.match?(/\Av\d+\.\d+\.\d+\z/)
  raise Thor::Error, "RAILS_MCP_TAG must be a release tag like v1.0.0, got #{tag.inspect}. Hosts never track a branch."
end

# Inside another project, the new app's bin/rails steps can load that
# project's bundle instead (rubygems-bundler wraps `rails` in the nearest
# Gemfile's bundle), so every install step fails on a missing gem.
parent_gemfile = Pathname(destination_root).parent.ascend.map { |dir| dir.join("Gemfile") }.find(&:exist?)
if parent_gemfile
  say "#{parent_gemfile} is above the new app. Delete #{destination_root} and run rails new " \
      "outside other Ruby projects, e.g. in ~/Development.", :red
  raise Thor::Error, "refusing to create a host inside #{parent_gemfile.dirname}"
end

unless options[:database] == "postgresql"
  say "rails_mcp hosts deploy to Heroku Postgres: re-run with -d=postgresql.", :red
  raise Thor::Error, "unsupported database #{options[:database].inspect}"
end

default_provider = app_name.sub(/[-_]mcp([-_]rails)?\z/, "").camelize
provider = ENV["PROVIDER"].presence ||
  ask("Provider name (the API this server wraps)?", default: default_provider).presence ||
  default_provider

# Heroku picks the Ruby version from the lockfile. Without a ruby line it
# builds with its own default rather than the app's .ruby-version.
inject_into_file "Gemfile", %(ruby file: ".ruby-version"\n), after: /\Asource .*\n/

if ENV["RAILS_MCP_PATH"].present?
  engine = File.expand_path(ENV["RAILS_MCP_PATH"])
  gem "rails_mcp", path: engine
else
  engine = tag
  gem "rails_mcp", git: "https://github.com/FutureWorkshops/rails-mcp.git", tag: tag
end

after_bundle do
  generate "rails_mcp:install", provider
  run "bundle install --quiet"

  # app_name is underscored; the directory keeps the name as typed.
  app_dir = File.basename(destination_root)
  say "\n#{'=' * 72}", :green
  say "#{app_dir}: rails_mcp (#{engine}) installed for #{provider}", :green
  say "=" * 72, :green
  say <<~NEXT

    Next: cd #{app_dir}, start Claude Code and paste:

      Read BUILDING_A_HOST.md in the rails_mcp engine
      (github.com/FutureWorkshops/rails-mcp) and CLAUDE.md in this app,
      then finish the #{provider} MCP server. The generator has already run.
      - API base URL: <...>
      - OAuth provider documentation: <...>
      - Tools to expose: <comma-separated list of operations>
      Walk through "What you still have to do". Before you start, ask me for
      the OAuth client_id / client_secret, the production APP_HOST, and
      confirmation of the tool list.

  NEXT
end
