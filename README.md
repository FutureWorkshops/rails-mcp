# rails_mcp

In-repo Rails engine that ships the shared scaffolding behind Future Workshops' Model Context Protocol (MCP) servers. The host app supplies the identity provider (Basecamp Launchpad, Xero, …), the API client, and the concrete tools; the engine supplies everything else.

This README is aimed at engineers wiring the engine into a new host app. The single most important section is **[Security responsibilities of the host](#security-responsibilities-of-the-host)** — the engine ships defaults for OAuth scopes, dynamic client registration, rate limits and so on, but several controls have to live in the host because they're environment- or identity-provider-specific.

## Building a new host

If you're bootstrapping a brand-new MCP server on top of this engine (Gmail, GitHub, Microsoft Graph, …), use the install generator:

```sh
# In a fresh Rails app, after adding the engine to the Gemfile pinned to a
# release tag (see Versioning):
#   gem "rails_mcp", git: "https://github.com/FutureWorkshops/rails-mcp.git", tag: "v1.0.0"
bundle install
bin/rails generate rails_mcp:install <Provider>
```

The generator writes routes, controllers, models, the API client skeleton, the host tool base class, every security initializer, the views, the Procfile, and patches `application.rb` + `production.rb`. After it runs you fill in 4 `# TODO` markers (OAuth URLs + scopes + API base), add credentials, write your tools, and deploy.

The full walkthrough lives at [`BUILDING_A_HOST.md`](BUILDING_A_HOST.md). This README describes the engine's API surface and the security boundary; the build guide describes how to use the generator and what's left to do afterwards.

## What's in the engine

- **MCP JSON-RPC dispatcher** at `POST /mcp` (initialize, tools/list, tools/call, batched arrays, notifications).
- **OAuth provider** via Doorkeeper, plus RFC 7591 dynamic client registration at `POST /oauth/register`.
- **RFC 8414 + RFC 9728 discovery documents** under `/.well-known/...`.
- **Identity model**: `RailsMcp::Account` (mirrored from the identity provider, preferring the user's home account), `User`, `Connection` (STI parent for host-specific concrete subclasses). There is no workspace setup, team management or invitation flow: accounts and membership come from Groundwork.
- **Authentication** controller concern and the `RailsMcp::OauthClientController` SSO base class.
- **`RailsMcp::BaseTool`** framework for host-specific MCP tools, with `RailsMcp::Registry` for discovery. Name tools **kebab-case, verb-first** (`list-todos`, `create-card`, `update-todo`) — the base class derives each tool's read-only / idempotent / destructive annotation from the leading verb, so correctly-named tools need no annotation code.
- **Defaults helpers**: `RailsMcp::RackAttackDefaults.apply!`.

## Versioning

The engine follows [Semantic Versioning](https://semver.org). Every release is a git tag (`vX.Y.Z`) with a GitHub release and an entry in [`CHANGELOG.md`](CHANGELOG.md), and `RailsMcp::VERSION` matches the tag.

- **Major** (`2.0.0`): a change a host must act on when upgrading (an initializer or config change, a migration with a manual step, a removed API), or one that refuses something the previous release accepted (a client registration, a sign-in, a token). The CHANGELOG entry carries an "Upgrading" checklist.
- **Minor** (`1.1.0`): backward-compatible features. A host can upgrade without changing anything.
- **Patch** (`1.0.1`): backward-compatible fixes only.

Hosts pin the engine **by tag**, never by branch:

```ruby
# Gemfile
gem "rails_mcp", git: "https://github.com/FutureWorkshops/rails-mcp.git", tag: "v1.0.0"
```

`branch: "main"` (or no ref at all) means whatever was last merged reaches production on the host's next `bundle update`, unreviewed by the host and with no record of which engine a deploy ran. A tag makes each engine upgrade a deliberate, reviewable Gemfile change in the host. To upgrade, read the CHANGELOG entries between your tag and the new one, follow any "Upgrading" steps, bump the tag and run `bundle update rails_mcp`.

Releasing: merge the release PR (it bumps `lib/rails_mcp/version.rb` and moves the CHANGELOG's Unreleased entries under the new version), then tag the merge commit `git tag -a vX.Y.Z -m "rails_mcp vX.Y.Z"`, push the tag, and create the GitHub release from the CHANGELOG entry.

## Mounting the engine

```ruby
# Gemfile (pin to a release tag, see Versioning)
gem "rails_mcp", git: "https://github.com/FutureWorkshops/rails-mcp.git", tag: "v1.0.0"

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
  c.tools          = -> { Mcp::Registry::ALL_TOOLS }    # or ->(user) { … } for per-user tool sets
  c.sign_in_path   = ->(_request) { "/basecamp/connect" }
  c.tool_error_handler = ->(error, **) { … }   # optional
end
```

See `basecamp-mcp-rails`' `config/initializers/rails_mcp.rb` for a working reference configuration.

### Migrations

**Do not run `rails_mcp:install:migrations`.** The engine appends its own `db/migrate` to the host's migration paths (see `append_migrations` in `lib/rails_mcp/engine.rb`), so engine migrations run straight from the gem:

```sh
bin/rails db:migrate
```

That's all a host needs, for first install and for every later engine bump. Copying the migrations into the host's `db/migrate` would duplicate them (they'd run once from the gem and again from the copy) and the host would then own files it has to keep in sync by hand. The host's `db/migrate` should contain only host-specific migrations (e.g. provider columns on `connections`); engine tables like `accounts` / `users` / `invitations` show up in `db/schema.rb` without ever being copied.

On deploy, the generated `Procfile`'s `release: bin/rails db:migrate` applies any new engine migrations automatically, so bumping the `rails_mcp` gem and pushing is enough; no manual migration step.

### Which OAuth clients may connect

Dynamic client registration (`POST /oauth/register`) needs no authentication, so where a self-registered client may have its authorization codes sent is restricted (`RailsMcp::RedirectUris`, the same rules as Groundwork's `Oauth::RedirectUris`):

- Claude's own connector callbacks, matched exactly: `https://claude.ai/api/mcp/auth_callback` and `https://claude.com/api/mcp/auth_callback`.
- Loopback over plain http on any port (`http://127.0.0.1`, `http://localhost`, `http://[::1]`), where Claude Code and other native clients listen. Allowed in production too.
- Any https URL (port 443) on a host listed in `config.allowed_redirect_hosts`, which defaults to the comma-separated `OAUTH_DCR_ALLOWED_REDIRECT_HOSTS` environment variable. The operator vouches for the whole host, so this is never a default.

Anything else is refused at registration with `invalid_redirect_uri`, and checked again at `/oauth/authorize` (`RailsMcp::OauthBaseController`) for every public client, so a client registered before the rule, or a host removed from the list, is stopped at once. That check answers with its own page and never redirects to the refused URI. Confidential (operator-created) clients are not held to the list. Registration also refuses a body that isn't a JSON object, more than 5 redirect URIs, or one longer than 2,048 characters.

To allow another connector, for example Grok:

```sh
heroku config:set -a <app> OAUTH_DCR_ALLOWED_REDIRECT_HOSTS=grok.com
```

or `c.allowed_redirect_hosts = %w[grok.com]` in `config/initializers/rails_mcp.rb` (which replaces the environment variable rather than adding to it).

### Standing at the identity provider (leavers, demotions, sessions)

The engine asks the identity provider about a user, through `config.identity_status`, whenever access is gained or renewed:

- on every **refresh** grant (`RailsMcp::RefreshTokenPolicy`),
- at the **consent screen**, `GET` and `POST /oauth/authorize` (`RailsMcp::OauthBaseController`),
- at **SSO sign-in** (`RailsMcp::OauthClientController#callback`).

Set it to `->(user) { GroundworkOauthController.identity_status(user) }`. That calls Groundwork `POST /oauth/user_status` with the app's client credentials, asking for the user's memberships (`include=memberships`), and returns a `RailsMcp::IdentityStanding`. What happens with the answer (`RailsMcp::IdentityCheck`):

| Groundwork says | Engine does |
|---|---|
| Active, and sends memberships | Updates the local role and mirrored account. A demotion takes effect on that refresh. Someone removed from the account they are mirrored into moves to their home account (or the first one they still belong to), with that account's role. |
| Active, no memberships (a Groundwork from before October 2026) | Nothing more: today's behaviour. |
| Inactive (deleted, a member of nothing, or 404: no record of the user authorising this app) | Refuses, revokes every token and grant the user holds, signs them out, and calls `config.on_user_deactivated`. |
| No usable answer (timeout, 401, 5xx) | Fails closed: the refresh gets 503 `temporarily_unavailable` with the refresh token left intact, so the client can retry; the consent screen says to try again in a few minutes. Logged as a warning and reported through `Rails.error` (`RailsMcp::IdentityUnavailable`). At sign-in alone it is let through, since the person has just authenticated at the IdP. |

`config.on_user_deactivated = ->(user) { user.connections.destroy_all }` deletes the leaver's stored upstream tokens (Google, Xero, Basecamp and so on). The engine never deletes them on its own. Revoke at the provider too in the hook if the provider supports it. A failing hook is reported and never stops the revocation.

Hosts that return a bare `:active` / `:inactive` / `:unknown` from their own `identity_status` still work; an `IdentityStanding` compares equal to its status symbol.

**Session lifetime.** The browser session the engine signs people in with lasts at most `config.session_lifetime` (default 12 hours; nil disables), measured from SSO sign-in. After that, or for a cookie from before 1.0 with no sign-in stamp, the session is reset and the person signs in through the IdP again. This is what stops a leaver's old cookie minting fresh tokens at `/oauth/authorize`. In the host's Doorkeeper initializer, `resource_owner_authenticator { RailsMcp::Authentication.resource_owner(self) }` resolves the user the same way (the base controller enforces the lifetime even for hosts that haven't switched).

**Refresh tokens.** Unused for `config.refresh_token_idle_days` (default 30; nil disables) they are refused. Replaying one that has already been rotated away revokes every token that user holds for that client.

Manual offboarding: `bin/rails rails_mcp:revoke_user[email]` revokes the user's tokens and deletes their provider connections.

### The MCP endpoint

`POST /mcp` never lets Rails parse the JSON body into params: the body is parsed only after the bearer token is checked, so an unauthenticated request costs nothing in proportion to its size. Bodies over `config.mcp_max_body_bytes` (default 1 MB) get 413 before anything else. An access token in the query string (`?access_token=`, `?bearer_token=`) is refused with 400, whatever the host's `access_token_methods`; send it in the `Authorization` header.

## Security responsibilities of the host

The engine handles the protocol-level security; the host owns the runtime environment. Both layers have to be wired up correctly or the deployed app has gaps.

### Already in the engine — no host action required

| Item | What the engine does | Where |
|---|---|---|
| Dynamic client registration validation | Redirect URIs must be Claude's callbacks, http loopback or an allowed https host; userinfo and fragments refused; at most 5 URIs of 2,048 chars; non-object bodies get 400. Caps `client_name` at 100 chars. | `app/controllers/rails_mcp/oauth/clients_controller.rb`, `lib/rails_mcp/redirect_uris.rb` |
| Authorize-time checks | Re-checks a public client's redirect URI, and the user's standing at the IdP, before Doorkeeper's consent screen. | `app/controllers/rails_mcp/oauth_base_controller.rb` |
| Standing on refresh | Role and account re-mirrored, leavers revoked, fail closed when the IdP can't answer. | `lib/rails_mcp/refresh_token_policy.rb`, `lib/rails_mcp/identity_check.rb` |
| Session lifetime | Engine browser sessions expire after `session_lifetime` (12 hours). | `app/controllers/concerns/rails_mcp/authentication.rb` |
| MCP body and token handling | Body not parsed before auth, 1 MB cap, no tokens in the query string. | `app/controllers/rails_mcp/mcp_controller.rb` |
| OAuth scope enforcement per tool | Read-only tools (`readOnlyHint: true`) require `:read`; everything else requires `:write`. Before-action accepts either; per-tool check refines. | `app/controllers/rails_mcp/mcp_controller.rb` |
| Doorkeeper authorize CSRF / PKCE | Doorkeeper config in the host's initializer pins `pkce_code_challenge_methods %w[S256]`; engine ships the matching base controller. | host `config/initializers/doorkeeper.rb` + `app/controllers/rails_mcp/oauth_base_controller.rb` |
| HEAD/GET verb confusion | `Authentication` concern stashes `session[:return_to]` on both verbs. | `app/controllers/concerns/rails_mcp/authentication.rb` |
| OAuth key log redaction | `:access_token`, `:refresh_token`, `:client_secret`, `:authorization`, `:bearer`, `:code` are auto-appended to `config.filter_parameters` at boot. | `lib/rails_mcp/engine.rb` (`OAUTH_FILTER_PARAMETERS`) |

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

**Error monitoring:** the engine doesn't ship an error reporter. Wire one up in the host as part of project setup — [Sentry](https://docs.sentry.io/platforms/ruby/guides/rails/) is the recommended choice. Add `gem "sentry-rails"` to the host Gemfile and configure it in an initializer. Be mindful of what reaches the reporter: scrub bearer tokens and other secrets (Sentry's `config.before_send` / `send_default_pii = false`) so request data and breadcrumbs don't leak credentials.

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
| 7 | **Force SSL, without `assume_ssl`.** `config.force_ssl = true`. Do **not** set `config.assume_ssl = true` behind Heroku's router: it tells Rails every request arrived over https, so `force_ssl` never redirects and the app serves plain http. The router's `X-Forwarded-Proto` already tells Rails the truth. | host `config/environments/production.rb` |
| 8 | **Doorkeeper `force_ssl_in_redirect_uri`.** `{ \|uri\| RailsMcp::RedirectUris.force_ssl?(uri) }`: https in production except loopback, where Claude Code listens. If you ever introduce a staging environment with `RAILS_ENV` != `production`, switch to an explicit rule so staging doesn't accept plain-`http://` redirect URIs. | host `config/initializers/doorkeeper.rb` |
| 8a | **Doorkeeper `access_token_methods :from_bearer_authorization`**, so no Doorkeeper-protected endpoint accepts a token in the URL. | host `config/initializers/doorkeeper.rb` |
| 9 | **Rate limit middleware** (Rack::Attack) — see *Opt-in helpers* above. | host `config/application.rb` + initializer |
| 10 | **Error monitoring.** Add an error reporter (Sentry recommended — `gem "sentry-rails"`) and configure it to scrub bearer tokens / secrets before send. The engine ships no reporter. | host `Gemfile` + initializer |
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
- `SENTRY_DSN` (recommended) — if you wire up Sentry for error monitoring

## Why `use_doorkeeper` isn't inside the engine

The engine declares `isolate_namespace RailsMcp`, which makes Rails resolve every controller mentioned in `RailsMcp::Engine.routes.draw` under the `RailsMcp::` namespace. Doorkeeper's controllers are top-level (`Doorkeeper::TokensController`, `Doorkeeper::AuthorizationsController`, …); if `use_doorkeeper` runs inside the engine's routes block, Rails tries to look them up as `RailsMcp::Doorkeeper::TokensController` and every `POST /oauth/token` 500s with `uninitialized constant RailsMcp::Doorkeeper`.

The fix is to declare `use_doorkeeper` at the **host's top level** (not inside `RailsMcp::Engine.routes.draw`). The engine still owns:

- `POST /oauth/register` (RFC 7591 dynamic client registration — our own controller, lives under the engine namespace correctly)
- `/.well-known/oauth-authorization-server` (its payload references the Doorkeeper URLs via `main_app.oauth_token_url(...)` etc.)

When `xero-mcp-rails` (or any future host) adopts the engine, it must add `use_doorkeeper` to its `config/routes.rb` next to the `mount` line.

## Running the engine specs

The engine has its own RSpec suite with a minimal Rails dummy app under `spec/dummy`.

```sh
cd spec/dummy && bin/rails db:create db:migrate RAILS_ENV=test && cd ../..
bundle exec rspec
```

GitHub Actions runs these specs and `bundler-audit` on every push to main and pull request (`.github/workflows/ci.yml`), and again every Friday night (`weekly-ci.yml`). Host apps' CI doesn't run them, so run them locally whenever you change engine code.
