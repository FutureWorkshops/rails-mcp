require "rails_helper"

RSpec.describe "Onboarding", type: :request do
  let(:account) { RailsMcp::Account.create!(name: "Default") }
  let(:user)    { account.users.create!(email: "u@example.com", identity_id: "id-1") }

  before do
    RailsMcp.configure do |c|
      c.sign_in_path = ->(_) { "/sign_in" }
      c.suggested_account_name = ->(u) { "Suggested for #{u.email}" }
    end
  end

  it "redirects unauthenticated users to the configured sign_in_path" do
    get "/onboarding"
    expect(response).to redirect_to("/sign_in")
  end

  context "signed in" do
    before { sign_in_as(user) }

    it "renders the onboarding form with the suggested account name" do
      get "/onboarding"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Suggested for u@example.com")
    end

    it "POST marks the account onboarded and redirects to /connections" do
      post "/onboarding", params: { name: "My Workspace" }
      expect(response).to redirect_to("/connections")
      expect(account.reload).to be_onboarded
      expect(account.name).to eq("My Workspace")
    end

    it "uses the suggested name when the form is blank" do
      post "/onboarding", params: { name: " " }
      expect(account.reload.name).to eq("Suggested for u@example.com")
    end

    it "redirects already-onboarded users to /connections" do
      account.mark_onboarded!
      get "/onboarding"
      expect(response).to redirect_to("/connections")
    end
  end
end
