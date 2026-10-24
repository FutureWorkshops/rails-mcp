require "rails_helper"

RSpec.describe "Refresh token policy", type: :request do
  let(:account) { RailsMcp::Account.create!(name: "Acme") }
  let(:user) { account.users.create!(email: "u@example.com", identity_id: "gw-1") }
  let(:client_app) { Doorkeeper::Application.create!(name: "Claude", redirect_uri: "https://claude.ai/cb", scopes: "read write", confidential: false) }

  around do |example|
    original_days = RailsMcp.config.refresh_token_idle_days
    original_status = RailsMcp.config.identity_status
    example.run
  ensure
    RailsMcp.config.refresh_token_idle_days = original_days
    RailsMcp.config.identity_status = original_status
  end

  def issue_token
    Doorkeeper::AccessToken.create!(application: client_app, resource_owner_id: user.id, scopes: "read write",
                                    expires_in: 3600, use_refresh_token: true)
  end

  def refresh(plaintext_refresh)
    post "/oauth/token", params: { grant_type: "refresh_token", refresh_token: plaintext_refresh, client_id: client_app.uid }
  end

  it "refreshes a recently used token" do
    token = issue_token
    refresh(token.plaintext_refresh_token)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["access_token"]).to be_present
  end

  it "refuses a refresh token idle for longer than the limit" do
    token = issue_token
    token.update_column(:created_at, 31.days.ago)

    refresh(token.plaintext_refresh_token)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["error"]).to eq("invalid_grant")
    expect(token.reload).to be_revoked
  end

  it "allows any age when idle expiry is disabled" do
    RailsMcp.config.refresh_token_idle_days = nil
    token = issue_token
    token.update_column(:created_at, 400.days.ago)
    refresh(token.plaintext_refresh_token)
    expect(response).to have_http_status(:ok)
  end

  it "refuses and revokes everything when the identity provider says the user has left" do
    RailsMcp.config.identity_status = ->(_user) { :inactive }
    token = issue_token
    other = issue_token

    refresh(token.plaintext_refresh_token)

    expect(response.parsed_body["error"]).to eq("invalid_grant")
    expect(token.reload).to be_revoked
    expect(other.reload).to be_revoked
  end

  it "fails closed, without revoking, when the identity provider can't be reached" do
    RailsMcp.config.identity_status = ->(_user) { :unknown }
    token = issue_token
    allow(Rails.error).to receive(:report)

    expect(Rails.logger).to receive(:warn).with(/refresh refused for user #{user.id}: identity provider could not confirm/)
    refresh(token.plaintext_refresh_token)

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body["error"]).to eq("temporarily_unavailable")
    expect(token.reload).not_to be_revoked
    expect(Rails.error).to have_received(:report).with(instance_of(RailsMcp::IdentityUnavailable), hash_including(handled: true))

    # Once the IdP answers again, the same refresh token works.
    RailsMcp.config.identity_status = ->(_user) { :active }
    refresh(token.plaintext_refresh_token)
    expect(response).to have_http_status(:ok)
  end

  it "revokes the whole token family when a rotated refresh token is replayed" do
    old = issue_token
    plaintext = old.plaintext_refresh_token
    refresh(plaintext)
    new_token = Doorkeeper::AccessToken.by_token(response.parsed_body["access_token"])
    old.revoke # what Doorkeeper does once the new access token is first used

    refresh(plaintext)

    expect(response.parsed_body["error"]).to eq("invalid_grant")
    expect(new_token.reload).to be_revoked
  end

  describe "standing re-read from the identity provider (ENG-02)" do
    let(:account) { RailsMcp::Account.create!(name: "Acme", groundwork_account_id: "100") }
    let(:user) { account.users.create!(email: "u@example.com", identity_id: "gw-1", role: "admin") }

    def groundwork_says(**kwargs)
      RailsMcp.config.identity_status = ->(_user) { RailsMcp::IdentityStanding.new(:active, **kwargs) }
    end

    it "downgrades a demoted admin on this refresh" do
      groundwork_says(accounts: [ { "id" => "100", "name" => "Acme", "role" => "member" } ])

      refresh(issue_token.plaintext_refresh_token)

      expect(response).to have_http_status(:ok)
      expect(user.reload).not_to be_admin
    end

    it "moves someone removed from the mirrored organisation to one they still belong to" do
      groundwork_says(home_account_id: "200", accounts: [ { "id" => "200", "name" => "Other", "role" => "member" } ])

      refresh(issue_token.plaintext_refresh_token)

      expect(response).to have_http_status(:ok)
      expect(user.reload.account.groundwork_account_id).to eq("200")
      expect(user.role).to eq("member")
    end

    it "revokes everything, and runs the host hook, when no membership is left" do
      groundwork_says(accounts: [])
      removed = nil
      RailsMcp.config.on_user_deactivated = ->(u) { removed = u }
      token = issue_token
      other = issue_token

      refresh(token.plaintext_refresh_token)

      expect(response.parsed_body["error"]).to eq("invalid_grant")
      expect([ token.reload, other.reload ]).to all(be_revoked)
      expect(removed).to eq(user)
    end

    it "keeps today's behaviour against a Groundwork that sends no memberships" do
      groundwork_says
      refresh(issue_token.plaintext_refresh_token)

      expect(response).to have_http_status(:ok)
      expect(user.reload).to be_admin
    end

    it "refuses and revokes when the user no longer exists locally" do
      groundwork_says
      token = issue_token
      user.delete

      refresh(token.plaintext_refresh_token)
      expect(response.parsed_body["error"]).to eq("invalid_grant")
      expect(token.reload).to be_revoked
    end
  end
end
