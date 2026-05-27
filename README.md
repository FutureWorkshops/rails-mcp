# rails_mcp

In-repo Rails engine that ships the shared scaffolding behind Future Workshops' Model Context Protocol (MCP) servers. The host app supplies the identity provider (Basecamp Launchpad, Xero, …), the API client, and the concrete tools; the engine supplies everything else.

This README is aimed at engineers wiring the engine into a new host app. The single most important section is **[Security responsibilities of the host](#security-responsibilities-of-the-host)** — the engine ships defaults for OAuth scopes, dynamic client registration, rate limits and so on, but several controls have to live in the host because they're environment- or identity-provider-specific.

## Building a new host

If you're bootstrapping a brand-new MCP server on top of this engine (Gmail, GitHub, Microsoft Graph, …), use the install generator:

```sh
# In a fresh Rails app, after adding `gem "rails_mcp"` to the Gemfile:
bundle install
bin/rails generate rails_mcp:install <Provider>
```

The generator writes routes, controllers, models, the API client skeleton, the host tool base class, every security initializer, the views, the Procfile, and patches `application.rb` + `production.rb`. After it runs you fill in 4 `# TODO` markers (OAuth URLs + scopes + API base), add credentials, write your tools, and deploy.

The full walkthrough lives at [`BUILDING_A_HOST.md`](BUILDING_A_HOST.md). This README describes the engine's API surface and the security boundary; the build guide describes how to use the generator and what's left to do afterwards.

## What's in the engine

- **MCP JSON-RPC dispatcher** at `POST /mcp` (initialize, tools/list, tools/call, batched arrays, notifications).
- **OAuth provider** via Doorkeeper, plus RFC 7591 dynamic client registration at `POST /oauth/register`.
- **RFC 8414 + RFC 9728 discovery documents** under `/.well-known/...`.
- **Identity model** — `RailsMcp::Account`, `User`, `Connection` (STI parent for host-specific concrete subclasses), `Invitation`.
- **Authentication** + **OnboardingGate** controller concerns.
- **InvitationsController**, **OnboardingController**, **TeamController** with views + mailer.
- **`RailsMcp::BaseTool`** framework for host-specific MCP tools, with `RailsMcp::Registry` for discovery. Name tools **kebab-case, verb-first** (`list-todos`, `create-card`, `update-todo`) — the base class derives each tool's read-only / idempotent / destructive annotation from the leading verb, so correctly-named tools need no annotation code.
- **Defaults helpers**: `RailsMcp::RackAttackDefaults.apply!`, `RailsMcp::ExceptionNotifierDefaults.apply!`.

## Mounting the engine

```ruby
# Gemfile
gem "rails_mcp", path: "engines/rails_mcp"

# config/routes.rb
mount RailsMcp::Engine => "/"
use_doorkeeper   # /oauth/authorize, /oauth/token, /oauth/revoke, /oauth/introspect
                 # MUST live in the host's routes — see "Why use_doorkeeper isn't
                 # inside the engine" below.

# config/initializers/rails_mcp.rb
RailsMcp.configure do |c|
  c.server_name    = "basecamp-mcp-rails"
  c.server_version = "0.1.0"
  c.display_name   = "Basecamp MCP"
  c.resource_name  = "Basecamp MCP Server"
  c.scopes         = %w[read write]
  c.tools          = -> { Mcp::Registry::ALL_TOOLS }
  c.sign_in_path   = ->(_request) { "/basecamp/connect" }
  c.tool_error_handler = ->(error, **) { … }   # optional
end
```

See `basecamp-mcp-rails`' `config/initializers/rails_mcp.rb` for a working reference configuration.

## Security responsibilities of the host

The engine handles the protocol-level security; the host owns the runtime environment. Both layers have to be wired up correctly or the deployed app has gaps.

### Already in the engine — no host action required

| Item | What the engine does | Where |
|---|---|---|
| Dynamic client registration validation | Rejects non-`https` (except loopback in non-prod), `javascript:`/`mailto:`/`file:`/`data:`, missing host, userinfo, fragments. Caps `client_name` at 100 chars. | `app/controllers/rails_mcp/oauth/clients_controller.rb` |
| OAuth scope enforcement per tool | Read-only tools (`readOnlyHint: true`) require `:read`; everything else requires `:write`. Before-action accepts either; per-tool check refines. | `app/controllers/rails_mcp/mcp_controller.rb` |
| Onboarding gate on `/mcp` | Returns JSON-RPC error (HTTP 403) until the resolved user's account is `onboarded?`. | `app/controllers/rails_mcp/mcp_controller.rb` |
| Doorkeeper authorize CSRF / PKCE | Doorkeeper config in the host's initializer pins `pkce_code_challenge_methods %w[S256]`; engine ships the matching base controller. | host `config/initializers/doorkeeper.rb` + `app/controllers/rails_mcp/oauth_base_controller.rb` |
| HEAD/GET verb confusion | `Authentication` concern stashes `session[:return_to]` on both verbs. | `app/controllers/concerns/rails_mcp/authentication.rb` |
| OAuth key log redaction | `:access_token`, `:refresh_token`, `:client_secret`, `:authorization`, `:bearer`, `:code` are auto-appended to `config.filter_parameters` at boot. | `lib/rails_mcp/engine.rb` (`OAUTH_FILTER_PARAMETERS`) |
| Mailer no-host fail-loudly | `RailsMcp::UserMailer#invite_email` raises if `default_url_options[:host]` is blank (no silent fallback to `localhost`). | `app/mailers/rails_mcp/user_mailer.rb` |

### Opt-in helpers — host calls them, engine provides them

**Rate limiting (Rack::Attack):** the engine bundles `rack-attack` and ships sensible throttles for the routes it owns; the host adds the middleware and opts in.

```ruby
# config/application.rb
require "rack/attack"
config.middleware.use Rack::Attack

# config/initializers/rack_attack.rb
Rack::Attack.cache.store = Rails.cache
RailsMcp::RackAttackDefaults.apply!
Rack::Attack.safelist("allow /up") { |req| req.path == "/up" }
```

Defaults (override by passing kwargs to `apply!`):
- `POST /oauth/register` — 5 per 15 min per IP
- `POST /mcp` — 120/min per token + 300/min per IP (fallback)
- `POST /team/invitations` — 20/hour per user

**Exception reporting to Slack:** the engine wraps the `exception_notification` + `slack-notifier` gems (which the host adds to its own Gemfile) and ships hardened defaults — only `backtrace` + `data` sections are sent, values starting with `Bearer ` or longer than 200 chars are redacted, and routing/bad-request errors are ignored.

```ruby
# config/initializers/exception_notification.rb
if Rails.env.production? && ENV["SLACK_WEBHOOK_URL"].present?
  RailsMcp::ExceptionNotifierDefaults.apply!(
    webhook_url: ENV["SLACK_WEBHOOK_URL"],
    channel:     ENV.fetch("SLACK_ERROR_CHANNEL", "#errors"),
    username:    "basecamp-mcp"
  )
end
```

### Host-only — the engine can't do these for you

These are environment- or identity-provider-specific, so they have to live in the host. Skipping any of them creates a real production gap. The list below is what `basecamp-mcp-rails` does; copy each pattern when you stand up a new host.

| # | What the host must do | Where |
|---|---|---|
| 1 | **Faraday timeouts on the upstream API client.** Without `open_timeout` / `read_timeout` / `write_timeout` a hung upstream pins a Puma worker until the platform request timeout fires. | host `app/services/<provider>_client_service.rb` |
| 2 | **`reset_session` at the unauth → auth boundary.** Call `reset_session` immediately before `session[:user_id] = user.id` in the identity-provider OAuth callback. Defeats session fixation. | host `app/controllers/<provider>_oauth_controller.rb#callback` |
| 3 | **Mailer host from `ENV.fetch("APP_HOST")`.** Use `ENV.fetch` (not `ENV[]`) so a misconfigured prod fails boot rather than silently sending invite links to `example.com`. | host `config/environments/production.rb` |
| 4 | **Content Security Policy.** Enable `config.content_security_policy`. At minimum: `default-src :self :https`, `object-src :none`, `frame-ancestors :none`, `base_uri :self`, `form-action` including the identity provider's authorize endpoint. Add nonce on `script-src` if you use inline scripts. | host `config/initializers/content_security_policy.rb` |
| 5 | **DNS rebinding protection.** Set `config.hosts = [ENV.fetch("APP_HOST"), …]`; exclude `/up` via `config.host_authorization`. | host `config/environments/production.rb` |
| 6 | **HSTS preload.** `config.ssl_options = { hsts: { expires: 2.years, subdomains: true, preload: true }, redirect: { exclude: ->(r) { r.path == "/up" } } }`. | host `config/environments/production.rb` |
| 7 | **Force SSL + assume SSL** when behind a TLS-terminating proxy (Heroku router, Cloudflare, etc.). `config.assume_ssl = true; config.force_ssl = true`. | host `config/environments/production.rb` |
| 8 | **Doorkeeper `force_ssl_in_redirect_uri`.** Use `{ Rails.env.production? }` for the simple case. If you ever introduce a staging environment with `RAILS_ENV` != `production`, switch to an explicit allowlist so staging doesn't accept plain-`http://` redirect URIs. | host `config/initializers/doorkeeper.rb` |
| 9 | **Rate limit middleware** (Rack::Attack) — see *Opt-in helpers* above. | host `config/application.rb` + initializer |
| 10 | **Slack exception notifier** — see *Opt-in helpers* above. Add `exception_notification` and `slack-notifier` to the host Gemfile. | host `Gemfile` + initializer |
| 11 | **Identity-provider OAuth state validation.** Generate `SecureRandom.hex(16)` (or larger) into `session[:<provider>_oauth_state]` on `/connect`, compare on callback (and `session.delete` the key — single use). | host `app/controllers/<provider>_oauth_controller.rb` |
| 12 | **Token refresh locking on the host's connection model.** Wrap the refresh attempt in `connection.with_lock` so concurrent MCP requests don't both hit the identity provider's token endpoint. | host `app/services/<provider>_client_service.rb` |
| 13 | **Production credentials key not in git.** `config/master.key` and `config/credentials/production.key` must be `.gitignore`d. Active Record encryption keys live in the credentials file, not committed. | host `.gitignore` + `config/credentials/` |
| 14 | **Run `bin/ci` before every commit.** Rubocop + brakeman + bundler-audit + importmap audit are the engine's contract to catch regressions; the host's CI script must run them all. | host `bin/ci` (or equivalent) |

### Deployment checklist

Required environment variables for a host using this engine on Heroku:

- `RAILS_MASTER_KEY` — Rails secret manager
- `APP_HOST` — public hostname (required by mailer + DNS rebinding protection; the host's `production.rb` calls `ENV.fetch("APP_HOST")` and will fail boot if missing)
- `DATABASE_URL` — provided by the Heroku Postgres add-on
- `SOLID_QUEUE_IN_PUMA=true` — run jobs inside the web dyno (or split out a worker dyno)
- `SLACK_WEBHOOK_URL` (optional) — enables the Slack exception notifier
- `SLACK_ERROR_CHANNEL` (optional, default `#errors`)

## Why `use_doorkeeper` isn't inside the engine

The engine declares `isolate_namespace RailsMcp`, which makes Rails resolve every controller mentioned in `RailsMcp::Engine.routes.draw` under the `RailsMcp::` namespace. Doorkeeper's controllers are top-level (`Doorkeeper::TokensController`, `Doorkeeper::AuthorizationsController`, …); if `use_doorkeeper` runs inside the engine's routes block, Rails tries to look them up as `RailsMcp::Doorkeeper::TokensController` and every `POST /oauth/token` 500s with `uninitialized constant RailsMcp::Doorkeeper`.

The fix is to declare `use_doorkeeper` at the **host's top level** (not inside `RailsMcp::Engine.routes.draw`). The engine still owns:

- `POST /oauth/register` (RFC 7591 dynamic client registration — our own controller, lives under the engine namespace correctly)
- `/.well-known/oauth-authorization-server` (its payload references the Doorkeeper URLs via `main_app.oauth_token_url(...)` etc.)

When `xero-mcp-rails` (or any future host) adopts the engine, it must add `use_doorkeeper` to its `config/routes.rb` next to the `mount` line.

## Running the engine specs

The engine has its own RSpec suite with a minimal Rails dummy app under `spec/dummy`.

```sh
cd engines/rails_mcp
cd spec/dummy && bin/rails db:create db:migrate RAILS_ENV=test && cd ../..
bundle exec rspec
```

The host's CI doesn't run the engine specs today. Run them whenever you change engine code.
