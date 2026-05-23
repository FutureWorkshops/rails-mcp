require "rails_helper"

RSpec.describe "Invitations landing", type: :request do
  let(:account) { RailsMcp::Account.create!(name: "Acme") }
  let(:inviter) { account.users.create!(email: "host@example.com", identity_id: "host") }
  let(:invitation) do
    account.invitations.create!(email: "guest@example.com", invited_by: inviter)
  end

  it "renders claimable state and stashes token in session" do
    get "/invite/#{invitation.token}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("You're invited")
    expect(session[RailsMcp::Invitation::SESSION_KEY]).to eq(invitation.token)
  end

  it "renders accepted state" do
    invitation.accept!
    get "/invite/#{invitation.token}"
    expect(response.body).to include("Already accepted")
    expect(session[RailsMcp::Invitation::SESSION_KEY]).to be_nil
  end

  it "renders revoked state" do
    invitation.revoke!
    get "/invite/#{invitation.token}"
    expect(response.body).to include("revoked")
  end

  it "renders expired state" do
    invitation.update!(expires_at: 1.day.ago)
    get "/invite/#{invitation.token}"
    expect(response.body).to include("expired")
  end

  it "returns 404 for unknown tokens" do
    get "/invite/bogus"
    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("not found")
  end
end
