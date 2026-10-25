# Changelog

All notable changes to the `rails_mcp` engine. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the engine uses [Semantic Versioning](https://semver.org): see README, **Versioning**. Hosts pin a release tag (`tag: "vX.Y.Z"`), never `branch: "main"`.

## [1.0.0] - Unreleased

The security release from the October 2026 engine audit (findings ENG-01 to ENG-10). Major because registrations, authorizations and refreshes that 0.2.0 accepted are now refused (see Upgrading).

### Upgrading from 0.2.0

1. **Gemfile:** pin the tag, `gem "rails_mcp", git: "https://github.com/FutureWorkshops/rails-mcp.git", tag: "v1.0.0"`, and run `bundle update rails_mcp`.
2. **`config/initializers/doorkeeper.rb`:** replace the `resource_owner_authenticator do ... end` block with `resource_owner_authenticator { RailsMcp::Authentication.resource_owner(self) }`, add `access_token_methods :from_bearer_authorization`, and change `force_ssl_in_redirect_uri { Rails.env.production? }` to `force_ssl_in_redirect_uri { |uri| RailsMcp::RedirectUris.force_ssl?(uri) }`. The engine enforces the session lifetime and the `/mcp` query-token refusal even without these lines; they make the rest of Doorkeeper match.
3. **Other connectors:** self-registered clients may now only redirect to Claude's callbacks, loopback, or an allowed https host. Before deploying, list the redirect hosts of your public OAuth applications (`Doorkeeper::Application.where(confidential: false).pluck(:name, :redirect_uri)`). For each one that must keep working, add its host to `OAUTH_DCR_ALLOWED_REDIRECT_HOSTS` (or `c.allowed_redirect_hosts`). **basecamp-mcp-rails** has a "Grok" client at `https://grok.com` (9 live tokens in October 2026): set `OAUTH_DCR_ALLOWED_REDIRECT_HOSTS=grok.com` if it should keep connecting. Its existing tokens keep refreshing either way; only new authorizations are refused.
4. **`config/initializers/rails_mcp.rb`:** add `c.on_user_deactivated = ->(user) { user.connections.destroy_all }` so a leaver's stored upstream tokens are deleted. Keep `c.identity_status = ->(user) { GroundworkOauthController.identity_status(user) }` as it is: it now returns memberships and roles when Groundwork sends them.
5. **`config/environments/production.rb`:** remove `config.assume_ssl = true`. Behind Heroku's router it makes `force_ssl` a no-op, so the app serves plain http. Keep `force_ssl`, HSTS and the `/up` redirect exclusion.
6. **Groundwork:** demotions and removals from one organisation take effect only once Groundwork's `/oauth/user_status` answers `include=memberships` (FutureWorkshops/Groundwork#44). Until then the engine keeps 0.2.0's active/inactive behaviour.
7. **Expect** everyone to sign in once more after the deploy: browser sessions from 0.2.0 carry no sign-in time and count as expired.

### Security
- **ENG-01:** dynamic client registration only accepts Claude's two connector callbacks (exact match), plain-http loopback on any port, and https hosts in `config.allowed_redirect_hosts` (default: the comma-separated `OAUTH_DCR_ALLOWED_REDIRECT_HOSTS` environment variable). Anything else is `invalid_redirect_uri`. `/oauth/authorize` checks a public client's redirect URI again, so clients registered under the old rule are stopped, and answers with its own page rather than redirecting to the refused URI.
- **ENG-02:** a user's role and mirrored account are re-read from Groundwork on every refresh, at the consent screen and at sign-in. A demotion takes effect on the next refresh; someone removed from the account they were mirrored into moves to their home account (or the first one they still belong to); someone left with no membership is revoked.
- **ENG-03:** the leaver check also runs at `/oauth/authorize` and SSO sign-in, and the engine's browser session has an absolute lifetime (`config.session_lifetime`, default 12 hours), so an old cookie can't mint fresh tokens.
- **ENG-04:** the identity check fails closed. A refresh Groundwork can't answer for gets 503 `temporarily_unavailable` (the refresh token stays valid for a retry) and the consent screen asks the person to try again; both log a warning and report `RailsMcp::IdentityUnavailable` through `Rails.error`. A 404 from `user_status` (no record of the user authorising this app) counts as inactive.
- **ENG-05:** `POST /mcp` never parses the JSON body into params, so nothing is parsed before the bearer token is checked, and bodies over `config.mcp_max_body_bytes` (default 1 MB) get 413.
- **ENG-07:** an access token in the `/mcp` query string is refused with 400, and the generated Doorkeeper config accepts tokens only from the `Authorization` header.
- **ENG-08:** registration answers 400 (not 500) for a body that isn't a JSON object, and caps redirect URIs at 5 of up to 2,048 characters. The consent screen no longer treats `https://localhost` as a known client.
- **ENG-09:** every call to the identity provider has a 3 second open and 5 second read timeout, and sign-in failures show a fixed sentence instead of the IdP's error parameter or an exception message (the detail is logged).
- **ENG-10:** `config.on_user_deactivated` is called with the user when a leaver is detected, after their tokens are revoked, so hosts can delete stored upstream credentials. A failing hook is reported and never stops the revocation.
- Generator: the production patch no longer writes `config.assume_ssl = true`, which turned `force_ssl` into a no-op on Heroku.

### Added
- `RailsMcp::RedirectUris`, `RailsMcp::IdentityStanding`, `RailsMcp::IdentityCheck`.
- `RailsMcp::Authentication.resource_owner(controller)` for Doorkeeper's authenticator, and `.start_session`.
- Configuration: `allowed_redirect_hosts`, `session_lifetime`, `on_user_deactivated`, `mcp_max_body_bytes`.
- `OauthClientController.http_open_timeout` / `.http_read_timeout` (3 and 5 seconds) for subclasses to override.
- This changelog, and a Versioning section in the README.

### Changed
- `OauthClientController.identity_status` returns a `RailsMcp::IdentityStanding` (which compares equal to `:active`, `:inactive` or `:unknown`), or nil when no `user_status_url` is set. Hosts may still return bare symbols from their own `identity_status` hooks.
- Plain-http loopback redirect URIs are accepted at registration in production too (Claude Code), with the matching `force_ssl_in_redirect_uri` rule.
- Install generator, README and BUILDING_A_HOST pin the engine by tag.

## [0.2.0] - 2026-10-24

Tagged after the fact at `c52c3d3`, the commit the FW MCP hosts ran in October 2026, so hosts can pin a tag. `RailsMcp::VERSION` still read `0.1.0` at that commit.

### Added
- Cowork Hub (Groundwork) SSO in the engine and the install generator (`RailsMcp::OauthClientController`).
- SSO mirrors the IdP account role onto `RailsMcp::User#role`, and the user's home account (userinfo `home_account_id`), falling back to `current_account_id`, then the first account.
- Refresh token policy: idle expiry (`refresh_token_idle_days`, default 30), a leaver check against Groundwork `POST /oauth/user_status` on every refresh (`identity_status`), and refresh token reuse detection.
- `rails rails_mcp:revoke_user[email]` for manual offboarding.
- Per-user tool sets: `c.tools` may be a proc taking the MCP user.
- GitHub Actions CI (bundler-audit and the spec suite) and a weekly run.

### Changed
- Stored OAuth tokens are hashed (`hash_token_secrets`, no plain-text fallback); migration `HashExistingOauthTokens` converts existing rows.
- PKCE required (`force_pkce`, S256 only) in the generated Doorkeeper config.
- The consent screen shows where the code will be sent and flags unverified redirect hosts (`trusted_redirect_hosts`).
- Generated CSP uses a per-request nonce; the production host allowlist no longer includes `*.herokuapp.com`.
- `accounts.cowork_account_id` renamed to `groundwork_account_id`.
- Ruby pinned to 4.0.6.

### Removed
- Workspace onboarding, `/team`, invitations and the invite mailer (accounts and membership come from Groundwork); the invitations table is dropped. `OnboardingGate` and the `mailer_from` / `suggested_account_name` writers remain as deprecated no-ops.
- The baked-in Slack exception notifier (Sentry recommended instead).

### Security
- The OAuth state check requires a present, matching value (constant time), closing login CSRF on the SSO callback.
- JSON-RPC batches capped at 20; malformed entries get JSON-RPC errors instead of 500s; unexpected tool errors return generic text.
- `format: false` on `/mcp` and `/oauth/register` so the throttles can't be bypassed with `.json`; the per-token throttle keys on a digest of the bearer.
- Tool `arguments` filtered from logs for every host.

## [0.1.0] - 2026-05-25

First tagged version: the MCP JSON-RPC dispatcher at `POST /mcp`, the Doorkeeper OAuth provider with RFC 7591 dynamic client registration, RFC 8414 and RFC 9728 discovery documents, the `Account` / `User` / `Connection` identity model, `RailsMcp::BaseTool` and `Registry`, `RackAttackDefaults`, and the `rails_mcp:install` generator.

[1.0.0]: https://github.com/FutureWorkshops/rails-mcp/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/FutureWorkshops/rails-mcp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/FutureWorkshops/rails-mcp/releases/tag/v0.1.0
