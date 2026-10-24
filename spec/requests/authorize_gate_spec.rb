require "rails_helper"

RSpec.describe "Authorization endpoint checks", type: :request do
  let(:account) { RailsMcp::Account.create!(name: "Acme", groundwork_account_id: "100") }
  let(:user) { account.users.create!(email: "u@example.com", identity_id: "gw-1", role: "admin") }
  let(:claude) { Doorkeeper::Application.create!(name: "Claude", redirect_uri: "https://claude.ai/api/mcp/auth_callback", scopes: "read write", confidential: false) }

  def authorize(app, redirect_uri: app.redirect_uri.split.first)
    get "/oauth/authorize", params: {
      client_id: app.uid, redirect_uri: redirect_uri, response_type: "code", scope: "read",
      code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", code_challenge_method: "S256", state: "s"
    }
  end

  describe "redirect URI re-check for clients registered before the allowlist (ENG-01)" do
    # Saved directly, as a row registered under the old rule would be.
    let(:legacy) do
      Doorkeeper::Application.create!(name: "Claude", redirect_uri: "https://attacker.example/cb", scopes: "read write", confidential: false)
    end

    it "answers with its own page and never redirects to the unapproved URI" do
      sign_in_as(user)
      authorize(legacy)

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("This connection can&#39;t be authorised")
      expect(response.location).to be_nil
      expect(Doorkeeper::AccessGrant.count).to eq(0)
    end

    it "refuses before sign-in too, so nobody is walked through SSO towards it" do
      authorize(legacy)
      expect(response).to have_http_status(:bad_request)
    end

    it "also refuses the consent POST" do
      sign_in_as(user)
      post "/oauth/authorize", params: {
        client_id: legacy.uid, redirect_uri: "https://attacker.example/cb", response_type: "code", scope: "read",
        code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", code_challenge_method: "S256"
      }
      expect(response).to have_http_status(:bad_request)
      expect(Doorkeeper::AccessGrant.count).to eq(0)
    end

    it "lets the client through once its host is allowed (Grok, say)" do
      grok = Doorkeeper::Application.create!(name: "Grok", redirect_uri: "https://grok.com/oauth/callback", scopes: "read write", confidential: false)
      sign_in_as(user)

      authorize(grok)
      expect(response).to have_http_status(:bad_request)

      RailsMcp.config.allowed_redirect_hosts = %w[grok.com]
      authorize(grok)
      expect(response).to have_http_status(:ok)
    end

    it "leaves confidential, operator-created clients alone" do
      operator = Doorkeeper::Application.create!(name: "Ops", redirect_uri: "https://ops.example/cb", scopes: "read", confidential: true)
      sign_in_as(user)
      authorize(operator)
      expect(response).to have_http_status(:ok)
    end

    it "shows the consent screen for Claude" do
      sign_in_as(user)
      authorize(claude)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "session lifetime (ENG-03)" do
    it "sends someone whose session is older than the lifetime back to sign in" do
      sign_in_as(user, signed_in_at: 13.hours.ago)
      authorize(claude)

      expect(response).to redirect_to("/sign_in")
      get "/protected"
      expect(response.body).to eq("nobody")
    end

    it "treats a session from before 1.0 (no sign-in stamp) as expired" do
      post "/test_sign_in", params: { user_id: user.id, legacy: 1 }
      authorize(claude)
      expect(response).to redirect_to("/sign_in")
    end

    it "honours a configured lifetime, and nil to switch it off" do
      RailsMcp.config.session_lifetime = 1.hour
      sign_in_as(user, signed_in_at: 2.hours.ago)
      get "/protected"
      expect(response.body).to eq("nobody")

      RailsMcp.config.session_lifetime = nil
      sign_in_as(user, signed_in_at: 400.days.ago)
      get "/protected"
      expect(response.body).to eq("hello u@example.com")
    end
  end

  describe "identity standing (ENG-02, ENG-03, ENG-04)" do
    it "signs out a leaver, revokes their tokens and runs the host hook" do
      token = Doorkeeper::AccessToken.create!(application: claude, resource_owner_id: user.id, scopes: "read", expires_in: 3600)
      deactivated = nil
      RailsMcp.config.identity_status = ->(_u) { RailsMcp::IdentityStanding.new(:inactive) }
      RailsMcp.config.on_user_deactivated = ->(u) { deactivated = u }
      sign_in_as(user)

      authorize(claude)

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("Your access has ended")
      expect(token.reload).to be_revoked
      expect(deactivated).to eq(user)
      get "/protected"
      expect(response.body).to eq("nobody")
    end

    it "fails closed, keeping the session, when the identity provider can't be asked" do
      RailsMcp.config.identity_status = ->(_u) { RailsMcp::IdentityStanding.new(:unknown, reason: "HTTP 401") }
      allow(Rails.error).to receive(:report)
      sign_in_as(user)

      authorize(claude)

      expect(response).to have_http_status(:service_unavailable)
      expect(response.body).to include("couldn&#39;t confirm your access")
      expect(response.body).not_to include("HTTP 401")
      expect(Rails.error).to have_received(:report).with(instance_of(RailsMcp::IdentityUnavailable), hash_including(handled: true))
      get "/protected"
      expect(response.body).to eq("hello u@example.com")
    end

    it "applies a demotion before showing the consent screen" do
      RailsMcp.config.identity_status = ->(_u) {
        RailsMcp::IdentityStanding.new(:active, accounts: [ { "id" => "100", "name" => "Acme", "role" => "member" } ])
      }
      sign_in_as(user)

      authorize(claude)

      expect(response).to have_http_status(:ok)
      expect(user.reload.role).to eq("member")
    end
  end
end
