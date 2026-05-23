module McpHelpers
  def make_user(email: "u@example.com", identity_id: "id-1")
    account = RailsMcp::Account.create!(name: "Acme")
    account.users.create!(email: email, identity_id: identity_id)
  end

  def issue_access_token_for(user)
    app = Doorkeeper::Application.create!(name: "Test", redirect_uri: "https://example/cb", scopes: "read write", confidential: false)
    Doorkeeper::AccessToken.create!(
      application_id: app.id,
      resource_owner_id: user.id,
      scopes: "read write",
      expires_in: 3600,
      use_refresh_token: false
    )
  end

  def mcp_call(body, token: nil)
    headers = { "CONTENT_TYPE" => "application/json" }
    headers["Authorization"] = "Bearer #{token.token}" if token
    post "/mcp", params: body.to_json, headers: headers
  end
end

RSpec.configure { |c| c.include McpHelpers, type: :request }
