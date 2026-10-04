require "rails_helper"
require "rake"

RSpec.describe "rails_mcp:revoke_user" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "rails_mcp:revoke_user" }
  end

  let(:client_app) { Doorkeeper::Application.create!(name: "C", redirect_uri: "https://claude.ai/cb", scopes: "read", confidential: false) }

  it "revokes the user's tokens and deletes their connections" do
    user = RailsMcp::Account.create!(name: "A").users.create!(email: "leaver@example.com", identity_id: "9")
    token = Doorkeeper::AccessToken.create!(application: client_app, resource_owner_id: user.id, scopes: "read", expires_in: 3600)
    user.connections.create!(type: "RailsMcp::Connection", external_id: "x", name: "x@example.com",
                             access_token: "a", refresh_token: "r", token_active: true)

    expect { Rake::Task["rails_mcp:revoke_user"].execute(Rake::TaskArguments.new([ :email ], [ "Leaver@Example.com" ])) }
      .to output(/Revoked 1 token\(s\) and deleted 1 connection\(s\)/).to_stdout

    expect(token.reload).to be_revoked
    expect(user.connections.reload).to be_empty
  end
end
