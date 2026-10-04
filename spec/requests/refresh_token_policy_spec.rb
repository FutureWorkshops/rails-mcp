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

  it "lets the refresh through when the identity provider can't be reached" do
    RailsMcp.config.identity_status = ->(_user) { :unknown }
    refresh(issue_token.plaintext_refresh_token)
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
end
