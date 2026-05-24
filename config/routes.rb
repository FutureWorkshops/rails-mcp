RailsMcp::Engine.routes.draw do
  # MCP JSON-RPC
  post "mcp", to: "mcp#handle"

  # OAuth provider — dynamic client registration (RFC 7591). The rest of the
  # Doorkeeper routes (`/oauth/authorize`, `/oauth/token`, `/oauth/revoke`,
  # `/oauth/introspect`) live in the host's routes.rb. Doorkeeper's controllers
  # are top-level (Doorkeeper::TokensController etc.) and our engine uses
  # `isolate_namespace RailsMcp`, which would make `use_doorkeeper` here try to
  # resolve them under `RailsMcp::Doorkeeper::*` and 500 every request.
  post "oauth/register", to: "oauth/clients#create", as: :oauth_register

  # Discovery
  get "/.well-known/oauth-authorization-server",
      to: "well_known#oauth_authorization_server",
      as: :oauth_authorization_server_metadata
  get "/.well-known/oauth-protected-resource",
      to: "well_known#oauth_protected_resource",
      as: :oauth_protected_resource_metadata
  get "/.well-known/oauth-protected-resource/*resource_path",
      to: "well_known#oauth_protected_resource"

  # User-facing
  get "invite/:token", to: "invitations#show", as: :invitation

  get  "onboarding", to: "onboarding#new",    as: :onboarding
  post "onboarding", to: "onboarding#create"

  get   "team",                  to: "team#index",              as: :team
  patch "team/account",          to: "team#update_account",     as: :team_update_account
  post  "team/invitations",      to: "team#create_invitation",  as: :team_invitations
  delete "team/invitations/:id", to: "team#destroy_invitation", as: :team_invitation
end
