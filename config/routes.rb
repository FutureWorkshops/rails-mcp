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

  # Workspace naming, team management and invitations were removed: accounts
  # and membership come from the identity provider (Groundwork). Old links
  # land on the host's Setup page.
  get "onboarding", to: redirect("/connections")
  get "team",       to: redirect("/connections")
end
