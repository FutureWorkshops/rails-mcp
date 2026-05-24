# Building a new MCP server on the `rails_mcp` engine

This is a mechanical, numbered build guide. Follow the 25 steps in order and you end up with a working MCP server: identity-provider OAuth, the engine's MCP/OAuth machinery, a per-provider API client with token refresh, host-side tools, security defaults, and a Heroku deploy.

> **Copy-paste prompt for Claude Code**
>
> Read `engines/rails_mcp/BUILDING_A_HOST.md` in full, then build an MCP server for **`<service name>`** in this directory.
>
> - API base URL: `<…>`
> - OAuth provider documentation: `<…>`
> - Tools to expose: `<comma-separated list of operations>`
> - Reference implementation: the sibling repo `basecamp-mcp-rails` is a fully-working host built on this engine. Open files there whenever the guide says "see basecamp's `<path>`".
>
> Before you start, ask me for:
> 1. The OAuth `client_id` / `client_secret`
> 2. The production `APP_HOST`
> 3. Confirmation of the tool list

`<Provider>` throughout this doc means the service you're integrating (e.g. `Gmail`, `Github`, `Xero`). Substitute everywhere.

The `rails_mcp` engine itself owns: the MCP JSON-RPC dispatcher at `/mcp`, the OAuth provider scaffolding (Doorkeeper + RFC 7591 dynamic client registration + RFC 8414/9728 discovery), the identity model (`Account` / `User` / `Connection` STI / `Invitation`), invitations + onboarding + team management, hardening defaults (Rack::Attack, exception notifier, OAuth log redaction). See `engines/rails_mcp/README.md` for the engine's full surface and the table of security responsibilities split between engine and host.

## Prerequisites

- Ruby `4.0.1` (matches the engine; see `.ruby-version`).
- PostgreSQL.
- Heroku CLI (`heroku login`).
- A fresh Rails 8 app: `rails new <provider>-mcp-rails -d=postgresql --skip-jbuilder` (or fork `basecamp-mcp-rails` as a starting point and prune).
- The `rails_mcp` engine, available as a path gem next to your host repo (or copied into `engines/rails_mcp/` inside the host).

## Reference map of basecamp-mcp-rails

When a step says "model on basecamp's `<path>`", open the corresponding file. Each path below is a working exemplar of the layer it lives in.

| Layer | Path |
|---|---|
| Identity-provider OAuth controller | `app/controllers/basecamp_oauth_controller.rb` |
| Connection STI subclass | `app/models/basecamp_connection.rb` |
| API client service | `app/services/basecamp_client_service.rb` |
| Host MCP tool base | `app/mcp/basecamp_tool.rb` |
| One concrete MCP tool | `app/mcp/tools/list_projects_tool.rb` |
| Tool registry | `app/mcp/registry.rb` |
| Engine config | `config/initializers/rails_mcp.rb` |
| Doorkeeper init | `config/initializers/doorkeeper.rb` |
| Rack::Attack init | `config/initializers/rack_attack.rb` |
| Exception notifier init | `config/initializers/exception_notification.rb` |
| Production env | `config/environments/production.rb` |
| Routes | `config/routes.rb` |
| Provider-specific connection columns | `db/migrate/20260523100001_add_basecamp_columns_to_connections.rb` |
| Procfile (Heroku) | `Procfile` |

---

## Phase 1 — Engine wiring

### Step 1: Gemfile

Add to your host's `Gemfile`:

```ruby
gem "rails_mcp", path: "engines/rails_mcp"     # or git: "...", branch: "main"

gem "doorkeeper",       "~> 5.8"
gem "faraday",          "~> 2.9"
gem "faraday-retry"

# Optional: error reporting to Slack.
gem "exception_notification"
gem "slack-notifier"

# Optional: provider-specific SDK (e.g. google-api-client for Gmail).
# gem "google-api-client"
```

Run `bundle install`.

### Step 2: Mount the engine + Doorkeeper

`config/routes.rb`:

```ruby
Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  mount RailsMcp::Engine => "/"   # /mcp, /oauth/register, /.well-known/*, /invite/:token, /onboarding, /team
  use_doorkeeper                  # /oauth/authorize, /oauth/token, /oauth/revoke, /oauth/introspect

  root "sessions#new"

  get    "sign_in",  to: "sessions#new",     as: :sign_in
  delete "sign_out", to: "sessions#destroy", as: :sign_out

  get "connections", to: "connections#index", as: :connections
  get "tools",       to: "tools#index",       as: :tools

  # Provider OAuth (filled in during Phase 2).
end
```

**Why `use_doorkeeper` is at the top level and not inside the engine mount:** the engine declares `isolate_namespace RailsMcp`, so if `use_doorkeeper` were declared inside `RailsMcp::Engine.routes.draw` Rails would try to resolve `Doorkeeper::TokensController` under the `RailsMcp::` namespace and 500 every `POST /oauth/token` with `uninitialized constant RailsMcp::Doorkeeper`. See README → "Why `use_doorkeeper` isn't inside the engine".

### Step 3: Create + migrate the database

```sh
bin/rails db:create db:migrate
```

The engine auto-appends its migrations to the host's migration paths (you don't need `rails_mcp:install:migrations`). After this step you have: `accounts`, `users`, `connections` (STI), `invitations`, plus the Doorkeeper tables.

### Step 4: `config/initializers/rails_mcp.rb`

Every attribute on `RailsMcp::Configuration` (defaults shown in comments):

```ruby
RailsMcp.configure do |c|
  c.server_name    = "<provider>-mcp-rails"           # → serverInfo.name
  c.server_version = "0.1.0"
  c.display_name   = "<Provider> MCP"                  # used in views + emails
  c.resource_name  = "<Provider> MCP Server"           # well-known protected_resource resource_name

  c.scopes = %w[read write]
  c.scope_descriptions = {
    "read"  => { title: "Read your <Provider> data",         detail: "…" },
    "write" => { title: "Create and update <Provider> data", detail: "…" }
  }

  # Host pointer to the array of tool classes (resolved on each /mcp call so
  # autoload reload in dev works).
  c.tools = -> { Mcp::Registry::ALL_TOOLS }

  # Where unauthenticated visitors are redirected. Point at your provider's
  # /<provider>/connect route — sign-in is OAuth, not a username/password form.
  c.sign_in_path = ->(_request) { "/<provider>/connect" }

  # Pre-fills the onboarding "Workspace name" field.
  c.suggested_account_name = ->(user) {
    user.connections.where(type: "<Provider>Connection").first&.name
  }

  # Optional. Maps per-tool exceptions to user-facing strings; nil falls
  # through to the engine's "Error: <message>" default.
  c.tool_error_handler = ->(error, **) {
    case error
    when <Provider>ClientService::ReconnectRequired
      "Your <Provider> connection needs to be reconnected. Visit /connections to fix it."
    when Mcp::<Provider>ApiError
      "<Provider> API error (HTTP #{error.status}) at #{error.path}: #{error.summarize}"
    when ActiveRecord::RecordNotFound
      "Not found: #{error.message}"
    end
  }
end
```

---

## Phase 2 — Identity-provider OAuth

### Step 5: Map the upstream OAuth flow

From the provider's docs, write down three URLs and one scope list:

| Field | Example (Google) |
|---|---|
| Authorize URL | `https://accounts.google.com/o/oauth2/v2/auth` |
| Token URL | `https://oauth2.googleapis.com/token` |
| Identity / userinfo endpoint | `https://openidconnect.googleapis.com/v1/userinfo` |
| Required scopes | `openid email profile https://www.googleapis.com/auth/gmail.modify` |

Most flows are Authorization Code with refresh tokens. Some need PKCE on the upstream side (Google's recommended), some don't (Basecamp Launchpad).

### Step 6: `app/controllers/<provider>_oauth_controller.rb`

Use basecamp's `app/controllers/basecamp_oauth_controller.rb` as the working exemplar. The key responsibilities every host's OAuth controller must implement:

1. `connect` — generate a `SecureRandom.hex(16)` state, stash it in `session[:<provider>_oauth_state]`, redirect to the authorize URL with `client_id` / `redirect_uri` / `state` (+ scope, + PKCE challenge if your provider needs it).
2. `callback` —
   - Validate `params[:state] == session.delete(:<provider>_oauth_state)`; bail otherwise.
   - Exchange `params[:code]` for tokens (and an identity / userinfo lookup).
   - Call `RailsMcp::Invitation.consume_from_session!(session, candidate_email: identity_email)` so invited users land in the inviter's account.
   - Upsert a `RailsMcp::User` keyed by the provider's stable identity id (Google `sub`, Basecamp Launchpad `id`, GitHub `id`, etc.).
   - Upsert a `<Provider>Connection` with the tokens + provider-specific metadata.
   - **`reset_session` immediately before `session[:user_id] = user.id`** — defeats session fixation across the privilege boundary. (Engine has no way to enforce this for you; see README → host responsibility #2.)
3. `disconnect` — find the current_user's connection by `external_id`, destroy it.

Skeleton (adapt provider-specific bits — token exchange method, identity payload shape, etc.):

```ruby
class <Provider>OauthController < ApplicationController
  before_action :require_sign_in, only: [ :disconnect ]

  AUTHORIZE_URL = "https://…"
  TOKEN_URL     = "https://…"
  USERINFO_URL  = "https://…"

  def connect
    state = SecureRandom.hex(16)
    session[:<provider>_oauth_state] = state
    query = { client_id: AppConfig.<provider>_client_id,
              redirect_uri: AppConfig.<provider>_redirect_uri,
              scope: "...",
              response_type: "code",
              state: state }.to_query
    redirect_to "#{AUTHORIZE_URL}?#{query}", allow_other_host: true
  end

  def callback
    if params[:state] != session.delete(:<provider>_oauth_state)
      return redirect_to root_path, alert: "Invalid OAuth state. Please try again."
    end
    return redirect_to(root_path, alert: "Authorisation failed: #{params[:error]}") if params[:error].present?

    tokens   = exchange_code(params[:code])
    identity = fetch_userinfo(tokens[:access_token])

    invitation = consume_invitation(identity["email"])
    return if performed?

    user = upsert_user(identity, account: invitation&.account)
    invitation&.accept!
    upsert_connection(user, tokens, identity)

    reset_session                       # ← MUST come before setting user_id
    session[:user_id] = user.id
    redirect_to "/connections", notice: "Signed in."
  rescue StandardError => e
    Rails.logger.error("<Provider> OAuth callback failed: #{e.class}: #{e.message}")
    redirect_to root_path, alert: "Sign-in failed: #{e.message}"
  end

  def disconnect
    conn = current_user.connections.find_by!(external_id: params[:external_id])
    name = conn.name
    conn.destroy
    redirect_to "/connections", notice: "#{name} disconnected."
  end

  private

  def consume_invitation(candidate_email)
    RailsMcp::Invitation.consume_from_session!(session, candidate_email: candidate_email) do |error|
      alert = { unknown: "Invitation link is no longer valid.",
                not_pending: "That invitation can no longer be claimed.",
                email_mismatch: "Signed in with a different email than the invitation." }[error]
      redirect_to root_path, alert: alert
    end
  end

  # exchange_code, fetch_userinfo, upsert_user, upsert_connection — see
  # basecamp_oauth_controller.rb for the full pattern.
end
```

### Step 7: Credentials

```sh
bin/rails credentials:edit
```

Add a provider block:

```yaml
<provider>:
  client_id: "..."
  client_secret: "..."
  redirect_uri: "http://localhost:3000/<provider>/callback"  # dev default
  contact_email: "your-team@example.com"                     # for API User-Agent
```

Reference these via a `config/initializers/app_config.rb` module (see basecamp's `app_config.rb`). Don't read credentials directly from controllers — keeps the rest of the app testable.

### Step 8: Routes for the OAuth flow

```ruby
# config/routes.rb, alongside the dashboard routes from Step 2
get    "<provider>/connect",                   to: "<provider>_oauth#connect",    as: :<provider>_connect
get    "<provider>/callback",                  to: "<provider>_oauth#callback",   as: :<provider>_callback
delete "<provider>/accounts/:external_id",     to: "<provider>_oauth#disconnect", as: :<provider>_disconnect
```

Register the dev redirect URI (`http://localhost:3000/<provider>/callback`) and the prod one (`https://<APP_HOST>/<provider>/callback`) with the upstream provider's app console.

---

## Phase 3 — Data model

### Step 9: Connection STI subclass + migration

`app/models/<provider>_connection.rb`:

```ruby
class <Provider>Connection < RailsMcp::Connection
  # Inherits: user belongs_to, encrypted access_token/refresh_token, token state
  # methods (token_expired?, needs_reconnect?, mark_refresh_failed!,
  # mark_refresh_succeeded!), with_lock helper.

  # Map external_id to a domain-friendly accessor if the provider has one:
  def <provider>_user_id = external_id
end
```

Host migration to add provider-specific columns to the engine's shared `connections` table (basecamp added `product`, `href`, `app_href`):

```ruby
class Add<Provider>ColumnsToConnections < ActiveRecord::Migration[8.1]
  def change
    add_column :connections, :<custom_column_1>, :string
    add_column :connections, :<custom_column_2>, :string
  end
end
```

`bin/rails db:migrate`.

### Step 10: `ApplicationController` includes engine concerns

```ruby
class ApplicationController < ActionController::Base
  include RailsMcp::Authentication    # current_user, signed_in?, require_sign_in
  include RailsMcp::OnboardingGate    # require_onboarding before_action helper

  allow_browser versions: :modern
end
```

`current_user` resolves the engine's `RailsMcp::User` via `session[:user_id]`. `require_sign_in` redirects unauthenticated users to `RailsMcp.config.sign_in_path` (set in Step 4). `require_onboarding` is a separate before_action you add per controller — see basecamp's `connections_controller.rb` and `tools_controller.rb`.

---

## Phase 4 — API client

### Step 11: `app/services/<provider>_client_service.rb`

Model on basecamp's `basecamp_client_service.rb`. The class must:

- Expose `<Provider>ClientService.for_connection(connection)` returning a Faraday connection bound to the provider's API base URL.
- Apply `open_timeout: 5`, `read_timeout: 10`, `write_timeout: 5` (or your tuned values) — **never ship without timeouts** or a hung upstream pins a Puma worker.
- Auto-refresh the OAuth token before requests, inside `connection.with_lock` so concurrent MCP requests don't both hit the token endpoint.
- On a permanent refresh error (`invalid_grant`, `invalid_client`, `unauthorized_client`, or your provider's equivalent), call `connection.mark_refresh_failed!(error_code)` and raise `ReconnectRequired`.
- On success, call `connection.mark_refresh_succeeded!(access_token:, refresh_token:, expires_in:)`.

```ruby
class <Provider>ClientService
  API_BASE  = "https://api.<provider>.com".freeze
  TOKEN_URL = "https://oauth.<provider>.com/token".freeze
  PERMANENT_REFRESH_ERRORS = %w[invalid_grant invalid_client unauthorized_client].freeze

  OPEN_TIMEOUT = 5; READ_TIMEOUT = 10; WRITE_TIMEOUT = 5

  class ReconnectRequired < StandardError
    attr_reader :connection, :error_code
    def initialize(connection, error_code = nil)
      @connection, @error_code = connection, error_code
      super("<Provider> connection #{connection.user.email.inspect} needs to be reconnected#{" (#{error_code})" if error_code}")
    end
  end

  def self.for_connection(connection) = new(connection).faraday

  def initialize(connection) = @connection = connection

  def faraday
    raise ReconnectRequired.new(@connection, @connection.token_refresh_error) if @connection.needs_reconnect?
    refresh_if_needed

    Faraday.new(url: "#{API_BASE}/") do |f|
      f.request :json
      f.request :retry, max: 2, interval: 0.2, backoff_factor: 2,
                        exceptions: [ Faraday::TimeoutError, Faraday::ConnectionFailed ]
      f.response :json, content_type: /\bjson$/
      f.headers["Authorization"] = "Bearer #{@connection.access_token}"
      f.headers["User-Agent"]    = AppConfig.<provider>_user_agent
      f.headers["Accept"]        = "application/json"
      f.options.open_timeout  = OPEN_TIMEOUT
      f.options.read_timeout  = READ_TIMEOUT
      f.options.write_timeout = WRITE_TIMEOUT
      f.adapter Faraday.default_adapter
    end
  end

  private

  def refresh_if_needed
    permanent = nil
    @connection.with_lock do
      return unless @connection.token_expired?
      response = Net::HTTP.post_form(URI(TOKEN_URL),
        grant_type: "refresh_token",
        refresh_token: @connection.refresh_token,
        client_id: AppConfig.<provider>_client_id,
        client_secret: AppConfig.<provider>_client_secret)
      body = JSON.parse(response.body) rescue {}
      if response.code == "200"
        @connection.mark_refresh_succeeded!(
          access_token: body["access_token"],
          refresh_token: body["refresh_token"] || @connection.refresh_token,
          expires_in: body["expires_in"])
      elsif PERMANENT_REFRESH_ERRORS.include?(body["error"])
        permanent = body["error"]
      else
        raise "Token refresh failed: #{body['error_description'] || body['error'] || response.code}"
      end
    end
    return unless permanent
    @connection.mark_refresh_failed!(permanent)
    raise ReconnectRequired.new(@connection, permanent)
  end
end
```

### Step 12: `config/initializers/doorkeeper.rb`

```ruby
Doorkeeper.configure do
  orm :active_record

  resource_owner_authenticator do
    if session[:user_id] && (user = RailsMcp::User.find_by(id: session[:user_id]))
      user
    else
      session[:return_to] = request.fullpath
      redirect_to("/<provider>/connect", alert: "Sign in to authorize this connection.")
    end
  end

  use_refresh_token
  default_scopes  :read
  optional_scopes :write
  enforce_configured_scopes
  grant_flows %w[authorization_code refresh_token]
  pkce_code_challenge_methods %w[S256]

  access_token_expires_in 8.hours
  reuse_access_token

  force_ssl_in_redirect_uri { Rails.env.production? }
  base_controller "RailsMcp::OauthBaseController"
end
```

---

## Phase 5 — MCP tools

### Step 13: Host tool base class

`app/mcp/<provider>_tool.rb` — see basecamp's `app/mcp/basecamp_tool.rb`. It inherits `RailsMcp::BaseTool` and adds:

- `client(external_id = nil)` — looks up the user's connection (single by default; by external_id when explicit) and returns a Faraday connection.
- `find_connection(external_id = nil)` — same lookup; raises `ActiveRecord::RecordNotFound` if missing.
- HTTP helpers: `get_json(conn, path)`, `post_json(conn, path, payload)`, `put_json`, `delete_json`, `raise_for_status`.
- A `<Provider>ApiError` class so the controller's `tool_error_handler` can recognise upstream HTTP failures.

### Step 14: Concrete tools

Naming convention drives MCP annotations automatically (see Appendix A). One file per tool under `app/mcp/tools/`. Template:

```ruby
module Mcp::Tools
  class List<Things>Tool < Mcp::<Provider>Tool
    def self.tool_name   = "list-<things>"
    def self.description = "List <things> in the connected account."
    def self.input_schema
      {
        type: "object",
        properties: {
          page: { type: "integer", description: "1-indexed page number" }
        }
      }
    end

    def call(page: 1, **)
      conn = client
      data = get_json(conn, "<things>", page: page)
      format_result(data)
    end
  end
end
```

### Step 15: `app/mcp/registry.rb`

```ruby
module Mcp
  module Registry
    ALL_TOOLS = [
      Tools::List<Things>Tool,
      Tools::Get<Thing>Tool,
      Tools::Create<Thing>Tool,
      # …
    ].freeze
  end
end
```

The `c.tools = -> { Mcp::Registry::ALL_TOOLS }` line in `config/initializers/rails_mcp.rb` (Step 4) wires this list into the engine's `tools/list` response.

---

## Phase 6 — Security wiring

### Step 16: Rack::Attack

`config/application.rb`:

```ruby
require "rack/attack"
config.middleware.use Rack::Attack
```

`config/initializers/rack_attack.rb`:

```ruby
require "rack/attack"

Rack::Attack.cache.store = Rails.cache
RailsMcp::RackAttackDefaults.apply!

Rack::Attack.throttled_responder = lambda do |request|
  retry_after = (request.env["rack.attack.match_data"] || {})[:period] || 60
  [ 429, { "content-type" => "application/json", "retry-after" => retry_after.to_s },
    [ { error: "rate_limited", error_description: "Too many requests; retry after #{retry_after}s." }.to_json ] ]
end

Rack::Attack.safelist("allow /up") { |req| req.path == "/up" }
```

Defaults installed: `/oauth/register` 5/15min/IP, `/mcp` 120/min/token + 300/min/IP fallback, `/team/invitations` 20/hour/user. Override via kwargs on `apply!` if needed.

### Step 17: Exception notifier (optional, Slack)

`config/initializers/exception_notification.rb`:

```ruby
if Rails.env.production? && ENV["SLACK_WEBHOOK_URL"].present?
  RailsMcp::ExceptionNotifierDefaults.apply!(
    webhook_url: ENV["SLACK_WEBHOOK_URL"],
    channel:     ENV.fetch("SLACK_ERROR_CHANNEL", "#errors"),
    username:    "<provider>-mcp"
  )
end
```

The engine's defaults already redact `Bearer …` and any data value longer than 200 chars, ship only `backtrace` + `data` sections, and ignore `ActionController::RoutingError` / `ActionController::BadRequest`.

### Step 18: Content Security Policy

`config/initializers/content_security_policy.rb`:

```ruby
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self, :https
    policy.font_src    :self, :https, :data
    policy.img_src     :self, :https, :data
    policy.object_src  :none
    policy.script_src  :self, :https
    policy.style_src   :self, :https, :unsafe_inline   # Cowork theme uses inline styles
    policy.connect_src :self, :https
    policy.frame_ancestors :none
    policy.base_uri    :self
    policy.form_action :self, "<authorize URL host, e.g. https://accounts.google.com>"
  end

  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[script-src]
end
```

`:unsafe_inline` for `style-src` is only needed if you adopt the Cowork Hub theme (Step 20). Drop it if you build a classed-CSS UI.

### Step 19: Production environment

`config/environments/production.rb`:

```ruby
config.assume_ssl = true
config.force_ssl  = true
config.ssl_options = {
  hsts: { expires: 2.years, subdomains: true, preload: true },
  redirect: { exclude: ->(request) { request.path == "/up" } }
}

config.action_mailer.default_url_options = {
  host:     ENV.fetch("APP_HOST"),   # loud boot failure if unset
  protocol: "https"
}

config.hosts = [
  ENV.fetch("APP_HOST"),
  /.*\.herokuapp\.com/
] + ENV.fetch("EXTRA_ALLOWED_HOSTS", "").split(",").map(&:strip).reject(&:blank?)

config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
```

OAuth log keys (`access_token`, `refresh_token`, `client_secret`, `authorization`, `bearer`, `code`) are auto-appended to `config.filter_parameters` by the engine — you don't need to add them in `filter_parameter_logging.rb`.

---

## Phase 7 — UI

### Step 20: Cowork Hub theme assets

Copy verbatim from basecamp-mcp-rails:

- `app/views/shared/_cowork_tokens.html.erb` — CSS custom properties + utility classes (`.cw-panel`, `.cw-btn`, `.cw-form-input`, …).
- `app/views/shared/_fw_logo.html.erb` — FW logomark SVG.
- `app/views/shared/_flash.html.erb` — flash partial.

Skip this step if you'd rather build a different design system.

### Step 21: Layout + dashboard views/controllers

Adapt from basecamp:

- `app/views/layouts/application.html.erb` — renders `shared/cowork_tokens`, sticky nav with logo + account name + sign-out, `flash` partial, `<%= yield %>`.
- `app/controllers/sessions_controller.rb` — `new` action shows "Sign in with <Provider>", `destroy` does `reset_session` and redirects.
- `app/controllers/connections_controller.rb` — lists `current_user.connections.where(type: "<Provider>Connection")`.
- `app/controllers/tools_controller.rb` — lists tools grouped read-only vs. write, reading `RailsMcp.config.tool_classes`.
- Matching views under `app/views/{sessions,connections,tools}/`.

### Step 22: Doorkeeper authorize override

Copy `app/views/doorkeeper/authorizations/new.html.erb` from basecamp and rebrand. The engine ships a generic default at `engines/rails_mcp/app/views/rails_mcp/doorkeeper/authorizations/new.html.erb`; Rails view resolution picks up the host's copy first when present.

---

## Phase 8 — Heroku deploy

### Step 23: Procfile

```
release: bin/rails db:migrate
web: bin/rails server -p ${PORT:-3000}
```

`release` runs every deploy and applies any pending engine + host migrations. If you use Solid Cache / Queue / Cable on a single `DATABASE_URL` (Heroku does), copy basecamp's `db/migrate/20260523200001_create_solid_cache_tables.rb` (and the queue + cable equivalents) so those tables actually exist on the primary DB. See *Common pitfalls* below.

### Step 24: Create the app + set env

```sh
heroku create <provider>-mcp-rails
heroku addons:create heroku-postgresql:essential-0
heroku config:set RAILS_MASTER_KEY=$(cat config/master.key)
heroku config:set APP_HOST=<provider>-mcp-rails.herokuapp.com   # or your custom domain
heroku config:set SOLID_QUEUE_IN_PUMA=true                       # runs Solid Queue inside the web dyno
heroku config:set SLACK_WEBHOOK_URL=https://hooks.slack.com/...  # optional
heroku config:set SLACK_ERROR_CHANNEL=#<provider>-mcp-errors     # optional
```

`APP_HOST` is required — `production.rb` calls `ENV.fetch("APP_HOST")` and the boot fails loudly without it (better than silently emailing invitations from `example.com`).

### Step 25: Ship + smoke test

```sh
git push heroku main
```

Verify after the deploy:

- `curl -s -o /dev/null -w "%{http_code}\n" https://<APP_HOST>/up` → `200`
- `curl https://<APP_HOST>/.well-known/oauth-authorization-server | jq .` → expected JSON (issuer, endpoints, scopes)
- `curl -i -X POST https://<APP_HOST>/mcp -d '{}' -H 'Content-Type: application/json'` → `401` with a `WWW-Authenticate: Bearer resource_metadata="…"` header
- Visit `https://<APP_HOST>/`, sign in via the provider OAuth, fill in the onboarding workspace name, land on `/connections`
- From Claude Desktop, add the connector at `https://<APP_HOST>/mcp`; the OAuth dance should complete and `tools/list` should return your tools.

---

## Verification checklist

| Phase | What to confirm |
|---|---|
| 1 | `bin/rails db:migrate:status` shows engine migrations applied; `bin/rails routes` shows `/oauth/token` routed to `doorkeeper/tokens#create` (not `rails_mcp/doorkeeper/...`). |
| 2 | `bin/rails s`; GET `/<provider>/connect` redirects to the provider's authorize URL. |
| 3 | `RailsMcp::User.last.connections.first` is a `<Provider>Connection`. |
| 4 | A read-only tool callable via `tool_class.new(current_user: user).call(...)` from a Rails console. |
| 5 | `RailsMcp.config.tool_classes.size` matches your tool count. |
| 6 | `curl -X POST http://localhost:3000/oauth/register …` returns 200 the first 5 times and 429 on the 6th (within 15 min). |
| 7 | Sign-in → onboarding form → `/connections` shows the linked account. |
| 8 | All of Step 25's smoke checks pass against the deployed Heroku app. |

After every code change, run `bin/ci` — rspec + rubocop + brakeman + bundler-audit + importmap audit must be green before commit.

---

## Reference: host security responsibilities

The engine handles the protocol-level security (OAuth scopes per tool, dynamic-client-registration URI validation, RFC 9728 `WWW-Authenticate`, onboarding gate on `/mcp`, OAuth log redaction, brakeman verb confusion fix). **The host owns**: Faraday timeouts, `reset_session` at sign-in, `APP_HOST` env var, CSP, DNS rebinding (`config.hosts`), HSTS preload, `force_ssl + assume_ssl`, Doorkeeper `force_ssl_in_redirect_uri`, the Rack::Attack and exception_notifier opt-ins, identity-provider OAuth state validation, token refresh locking, credentials-key hygiene, `bin/ci` gating.

See `engines/rails_mcp/README.md` → **Security responsibilities of the host** for the complete table. That section is the source of truth; this guide doesn't restate it.

---

## Appendix A — Tool naming → annotation cheat sheet

`RailsMcp::BaseTool` auto-derives MCP annotations from the tool name prefix. Pick a name from a prefix below and the annotation is set for you.

| Prefix | Annotation set | Example |
|---|---|---|
| `list-`, `get-`, `search` | `readOnlyHint: true`, `idempotentHint: true` | `list-projects`, `get-thread`, `search-messages` |
| `delete-`, `trash-`, `archive-` | `destructiveHint: true` | `delete-card`, `trash-message`, `archive-thread` |
| `update-`, `complete-`, `uncomplete-`, `approve-`, `revert-`, `archive-`, `restore-` | `idempotentHint: true` | `update-todo`, `complete-todo`, `approve-timesheet` |

Subclasses can override `read_only_prefixes`, `destructive_prefixes`, `idempotent_prefixes` if a provider needs different verbs.

---

## Appendix B — Common pitfalls

- **`use_doorkeeper` inside the engine mount** → every `POST /oauth/token` 500s with `uninitialized constant RailsMcp::Doorkeeper`. Declare at the host's top-level routes block. (README → "Why `use_doorkeeper` isn't inside the engine".)
- **Missing `reset_session` in the OAuth callback** → session fixation across the privilege boundary. Engine can't enforce this for you.
- **Faraday without timeouts** → a hung upstream pins a Puma worker until the platform's request timeout fires (Heroku H12 at 30s). Always set `open_timeout` / `read_timeout` / `write_timeout`.
- **Mailer host left at `example.com`** → invitation emails point at the wrong domain in prod. Read from `ENV.fetch("APP_HOST")` so prod boot fails loudly.
- **CSP `style-src :self :https` without `:unsafe_inline`** when using the Cowork Hub theme → all styles blocked. Drop `:unsafe_inline` only if your UI is purely classed CSS.
- **`config.hosts` not set in production** → DNS rebinding / Host-header attacks. Add `ENV.fetch("APP_HOST")` plus a `.herokuapp.com` regex.
- **Solid Cache / Queue / Cable on a single `DATABASE_URL`** → the gems' schemas don't get installed unless you copy them into `db/migrate/`. Without those migrations, the first cache write 500s with `PG::UndefinedTable: solid_cache_entries`.
- **Production credentials key committed to git** → encrypted columns become unrecoverable for everyone but you. `.gitignore` `config/master.key` and `config/credentials/*.key`.
- **Skipping `bin/ci` and trusting `bundle exec rspec`** → rubocop and the security scanners are part of GitHub Actions; commits that pass rspec alone can still fail CI.
