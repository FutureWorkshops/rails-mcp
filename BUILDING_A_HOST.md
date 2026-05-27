# Building a new MCP server on the `rails_mcp` engine

The engine ships a Rails generator (`rails_mcp:install`) that scaffolds the entire host. After running it, your remaining work is:

1. Fill in the upstream OAuth URLs and scopes (4 lines).
2. Set `API_BASE` for the API client (1 line).
3. Add credentials.
4. Write your MCP tools.
5. Heroku deploy.

That's it. The generator handles routes, controllers, models, the API client skeleton, the tool base class, all the security initializers (rate limiting, CSP, HSTS, DNS rebinding, exception reporting), the views, the Procfile, and patches `application.rb` + `production.rb`.

> **Copy-paste prompt for Claude Code**
>
> Read `engines/rails_mcp/BUILDING_A_HOST.md`, then build an MCP server for **`<service name>`** in this directory.
>
> - API base URL: `<…>`
> - OAuth provider documentation: `<…>`
> - Tools to expose: `<comma-separated list of operations>`
>
> Run `bin/rails generate rails_mcp:install <Provider>` first, then walk through the "What you still have to do" section.
>
> Before you start, ask me for the OAuth `client_id` / `client_secret`, the production `APP_HOST`, and confirmation of the tool list.

## Prerequisites

- Ruby `4.0.1` (`.ruby-version` in the engine repo).
- PostgreSQL.
- Heroku CLI (`heroku login`).
- A fresh Rails 8 app: `rails new <provider>-mcp-rails -d=postgresql --skip-jbuilder`.
- The `rails_mcp` engine, available as a path or git gem.

## One-line install

```sh
# In your fresh Rails app's Gemfile:
gem "rails_mcp", path: "../basecamp-mcp-rails/engines/rails_mcp"   # or git:

bundle install
bin/rails generate rails_mcp:install Gmail
```

The argument is your provider's name. `Gmail`, `gmail`, `github_api`, `XeroPayroll` are all accepted — the generator normalises to `CamelCase` for class names and `snake_case` for file paths.

## What the generator creates

| Layer | Files |
|---|---|
| Routes | `config/routes.rb` (mount engine + `use_doorkeeper` outside the engine namespace + identity-provider routes) |
| Controllers | `application_controller.rb` (includes engine concerns), `sessions_controller.rb`, `connections_controller.rb`, `tools_controller.rb`, `<provider>_oauth_controller.rb` |
| Models | `app/models/<provider>_connection.rb` (STI subclass of `RailsMcp::Connection`) |
| Services | `app/services/<provider>_client_service.rb` (Faraday with timeouts + token refresh under `with_lock` + permanent-error handling + `ReconnectRequired` exception) |
| MCP | `app/mcp/<provider>_tool.rb` (host tool base), `app/mcp/registry.rb` (empty `ALL_TOOLS`), `app/mcp/tools/.keep` |
| Initializers | `rails_mcp.rb`, `doorkeeper.rb`, `rack_attack.rb`, `exception_notification.rb`, `content_security_policy.rb`, `app_config.rb`, `zeitwerk.rb` (maps `app/mcp/*` → `Mcp::` namespace) |
| Views | `layouts/application.html.erb`, `shared/_cowork_tokens.html.erb`, `_fw_logo.html.erb`, `_flash.html.erb`, `sessions/new`, `connections/index`, `tools/index`, `doorkeeper/authorizations/new` |
| Patches | `config/application.rb` (Rack::Attack middleware), `config/environments/production.rb` (HSTS, `config.hosts`, mailer host) |
| Procfile | `release: bin/rails db:migrate`, `web: bin/rails server -p ${PORT}` |
| Gemfile | adds `doorkeeper`, `faraday`, `faraday-retry`, `rspec-rails`, `webmock` |

Everything in there comes from a battle-tested basecamp-mcp-rails template. You do not need to edit any of these files except where a `# TODO` marker is present.

---

## What you still have to do

The generator drops `# TODO` markers in three files. Search the project for `TODO` after running it.

### 1. OAuth URLs + scopes — `app/controllers/<provider>_oauth_controller.rb`

Open the file and replace the constants near the top:

```ruby
AUTHORIZE_URL = "https://TODO/authorize"
TOKEN_URL     = "https://TODO/token"
USERINFO_URL  = "https://TODO/userinfo"
SCOPES        = "TODO"
```

Quick reference (verify against the provider's own docs):

| Provider | Authorize / Token / Userinfo |
|---|---|
| Google (Gmail, Drive, Calendar, …) | `https://accounts.google.com/o/oauth2/v2/auth` · `https://oauth2.googleapis.com/token` · `https://openidconnect.googleapis.com/v1/userinfo` |
| GitHub | `https://github.com/login/oauth/authorize` · `https://github.com/login/oauth/access_token` · `https://api.github.com/user` |
| Microsoft Graph | `https://login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize` · `…/token` · `https://graph.microsoft.com/v1.0/me` |
| Xero | `https://login.xero.com/identity/connect/authorize` · `https://identity.xero.com/connect/token` · `https://api.xero.com/connections` |

Also adjust `identity_id` / `identity_email` / `identity_name` and the `upsert_connection` helper at the bottom of the file to match the shape of your provider's userinfo response (Google has `sub`, GitHub has `id`, Microsoft has `id`, …).

### 2. API base URL — `app/services/<provider>_client_service.rb`

```ruby
API_BASE  = "https://TODO.example.com"   # → e.g. "https://gmail.googleapis.com/gmail/v1"
TOKEN_URL = "https://TODO/token"          # same value as in the OAuth controller
```

If your provider returns different "permanent error" codes on refresh, update `PERMANENT_REFRESH_ERRORS` too. (Google = `invalid_grant`, GitHub = `bad_refresh_token`, Xero = `invalid_grant`/`unauthorized_client`.)

### 3. Credentials

```sh
bin/rails credentials:edit
```

Add a `<provider>:` block keyed by the provider's underscored name (matches what `app_config.rb` reads):

```yaml
<provider>:
  client_id:     "..."
  client_secret: "..."
  redirect_uri:  "http://localhost:3000/<provider>/callback"
  contact_email: "your-team@example.com"     # included in API User-Agent
```

Production overrides the redirect URI to `https://$APP_HOST/<provider>/callback` automatically.

### 4. Tools

Write each tool as a separate file under `app/mcp/tools/`, inheriting from the host tool base class (`Mcp::<Provider>Tool`). Then add it to `Mcp::Registry::ALL_TOOLS`.

**Name tools in kebab-case, verb-first: `list-threads`, `get-thread`, `create-card`, `update-todo`, `delete-message`.** This is the engine's native convention — `RailsMcp::BaseTool` auto-derives each tool's MCP annotation hints (read-only / idempotent / destructive) from the leading verb, so a correctly-named tool needs no annotation boilerplate. The mapping is in [Appendix A](#appendix-a--tool-naming--annotation-cheat-sheet). If you name tools any other way (e.g. snake_case `threads_list`), the prefix match fails and **every tool is treated as a destructive write** unless you override `self.annotations` in your host base class — don't, unless you have a deliberate reason.

```ruby
# app/mcp/tools/list_threads_tool.rb
module Mcp::Tools
  class ListThreadsTool < Mcp::GmailTool
    def self.tool_name   = "list-threads"
    def self.description = "List Gmail threads in the inbox."
    def self.input_schema
      {
        type: "object",
        properties: {
          query: { type: "string", description: "Gmail search query (e.g. 'is:unread')" },
          page:  { type: "integer", description: "1-indexed page" }
        }
      }
    end

    def call(query: "in:inbox", page: 1, **)
      conn = client
      data = get_json(conn, "users/me/threads", q: query, pageToken: page)
      format_result(data)
    end
  end
end
```

```ruby
# app/mcp/registry.rb
ALL_TOOLS = [
  Tools::ListThreadsTool,
  Tools::GetThreadTool,
  # …
].freeze
```

The tool name's prefix auto-derives the MCP annotation hints (see [Appendix A](#appendix-a--tool-naming--annotation-cheat-sheet)).

### 5. (Optional) Provider-specific Connection columns

If your provider returns metadata worth surfacing on the dashboard (Xero has `tenant_type`; Basecamp has `product`/`href`/`app_href`), add columns to the engine's shared `connections` table:

```sh
bin/rails g migration AddGmailColumnsToConnections workspace_url:string
```

Adjust `upsert_connection` in the OAuth controller to persist them and update the connections view if you want them rendered.

### 6. Run it

```sh
bin/rails db:create db:migrate
bin/rails server
```

Visit `http://localhost:3000`, sign in via the provider OAuth, claim onboarding, see your connection listed. From Claude Desktop, add a connector at `http://localhost:3000/mcp` and confirm `tools/list` returns your tools.

---

## Heroku deploy

```sh
heroku create <provider>-mcp-rails
heroku addons:create heroku-postgresql:essential-0
heroku config:set RAILS_MASTER_KEY=$(cat config/master.key)
heroku config:set APP_HOST=<provider>-mcp-rails.herokuapp.com
heroku config:set SOLID_QUEUE_IN_PUMA=true
heroku config:set SLACK_WEBHOOK_URL=https://hooks.slack.com/...   # optional
heroku config:set SLACK_ERROR_CHANNEL="#<provider>-mcp-errors"   # optional

git push heroku main
```

`APP_HOST` is required — `production.rb` calls `ENV.fetch("APP_HOST")` and boot fails loudly without it. The Procfile's `release` phase runs the engine + host migrations on every deploy.

Register the production redirect URI with the upstream provider's app console: `https://<APP_HOST>/<provider>/callback`.

### Smoke test the deploy

```sh
curl -s -o /dev/null -w "%{http_code}\n" https://<APP_HOST>/up
# → 200

curl -s https://<APP_HOST>/.well-known/oauth-authorization-server | jq .issuer
# → "https://<APP_HOST>"

curl -i -X POST https://<APP_HOST>/mcp -d '{}' -H 'Content-Type: application/json'
# → 401, WWW-Authenticate: Bearer resource_metadata="https://<APP_HOST>/.well-known/oauth-protected-resource"
```

Then sign in via the browser, finish onboarding, and reconnect from Claude Desktop at `https://<APP_HOST>/mcp`. The OAuth dance should complete and `tools/list` should return your tool count.

---

## Verification checklist

After each phase, confirm:

| Phase | What to confirm |
|---|---|
| Install | `bin/rails routes` shows `/oauth/token` → `doorkeeper/tokens#create` (not `rails_mcp/doorkeeper/...`). Engine migrations applied via `bin/rails db:migrate:status`. |
| OAuth | `GET /<provider>/connect` redirects to the provider's authorize URL with `state` set. |
| Client | From a Rails console: `<Provider>ClientService.for_connection(user.connections.first)` returns a Faraday connection (no exception). |
| Tools | `RailsMcp.config.tool_classes.size` matches your tool count; `tools/list` over MCP returns them. |
| Deploy | All three smoke checks above pass against the deployed Heroku app. |

After every code change, `bin/ci` must pass — rspec + rubocop + brakeman + bundler-audit + importmap audit — before commit.

---

## Reference: host security responsibilities

The engine ships defenses for: OAuth scopes per tool, dynamic-client-registration URI validation, RFC 9728 `WWW-Authenticate`, onboarding gate on `/mcp`, OAuth log redaction. The generator wires in: Faraday timeouts, `reset_session` at sign-in, `APP_HOST`-backed mailer host, CSP, DNS rebinding (`config.hosts`), HSTS preload, `force_ssl + assume_ssl`, Rack::Attack throttles, and the exception notifier defaults.

What you still own: identity-provider OAuth state validation (already in the generated controller — just don't delete it), token refresh locking (`with_lock` — already in the client service), credentials-key hygiene (`config/master.key` + `config/credentials/*.key` must be `.gitignore`d — Rails generators do this by default), running `bin/ci` before each commit.

See `engines/rails_mcp/README.md` → **Security responsibilities of the host** for the full table.

---

## Appendix A — Tool naming → annotation cheat sheet

`RailsMcp::BaseTool` auto-derives MCP annotations from the tool name prefix:

| Prefix | Annotation set | Example |
|---|---|---|
| `list-`, `get-`, `search` | `readOnlyHint: true`, `idempotentHint: true` | `list-threads`, `get-thread`, `search-messages` |
| `delete-`, `trash-`, `archive-` | `destructiveHint: true` | `delete-thread`, `trash-message`, `archive-thread` |
| `update-`, `complete-`, `uncomplete-`, `approve-`, `revert-`, `archive-`, `restore-` | `idempotentHint: true` | `update-label`, `approve-timesheet` |

Pick a name from a prefix; the engine sets the annotation hint that the MCP client uses to decide whether the call is safe to retry / commits side-effects.

**Use kebab-case verb-first names** so this works automatically. A name that doesn't start with one of the prefixes above gets `readOnlyHint: false` + `destructiveHint: false` + `idempotentHint: false` — i.e. it's treated as a non-idempotent write, and the engine's per-tool OAuth scope check will demand the `write` scope. If you must use a different convention (basecamp-mcp-rails mirrors its `basecamp-cli-mcp` sibling with snake_case `domain_action` names), override `self.annotations` in your host `Mcp::<Provider>Tool` base class to map your scheme onto the same hints. That's a deliberate, documented deviation — not the default path.

---

## Appendix B — Common pitfalls

- **`use_doorkeeper` inside the engine mount** → every `POST /oauth/token` 500s with `uninitialized constant RailsMcp::Doorkeeper`. The generator places it at the host's top-level routes block; don't move it into the engine mount.
- **Missing `reset_session` in the OAuth callback** → session fixation across the privilege boundary. The generated callback has it; don't delete it.
- **Faraday without timeouts** → a hung upstream pins a Puma worker until Heroku H12 fires at 30s. The generated client service has `OPEN_TIMEOUT`/`READ_TIMEOUT`/`WRITE_TIMEOUT`; don't remove them.
- **Mailer host left at `localhost`** → `production.rb` is patched to `ENV.fetch("APP_HOST")`; without `APP_HOST` set on Heroku, boot fails loudly. Set the env var before the first deploy.
- **CSP `form-action` not updated** → the generated CSP has `policy.form_action :self, "https://TODO"`. Replace `"https://TODO"` with your provider's authorize URL host, or the OAuth redirect from the browser will be blocked.
- **Solid Cache / Queue / Cable** on a single `DATABASE_URL` → if you use any of them, generate their schemas via `bin/rails solid_cache:install` (and `solid_queue`, `solid_cable`) then convert the generated schemas into migrations under `db/migrate/` so they land in the primary DB on `release`. See `basecamp-mcp-rails/db/migrate/20260523200001_create_solid_cache_tables.rb` for an example.
- **Re-running the generator on an existing project** offers Thor's standard overwrite prompts. Always review the diff (`git diff`) before accepting overwrites of files you've customised — particularly the OAuth controller and registry.
- **Deleting `config/initializers/zeitwerk.rb`** → every request that resolves the tool list 500s with `uninitialized constant Mcp`. The host's `app/mcp/*` files use the `Mcp::` namespace but live in a `app/<root>/*` autoload root by default; the generated initializer remaps the directory so Zeitwerk loads `Mcp::Registry` from `app/mcp/registry.rb` correctly. Keep it.
