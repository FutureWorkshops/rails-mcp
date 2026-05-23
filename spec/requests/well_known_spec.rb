require "rails_helper"

RSpec.describe "Well-known discovery", type: :request do
  before do
    RailsMcp.configure do |c|
      c.server_name = "test-mcp"
      c.display_name = "Test MCP"
      c.scopes = %w[read write]
    end
  end

  it "advertises the OAuth authorization server metadata (RFC 8414)" do
    get "/.well-known/oauth-authorization-server"
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["scopes_supported"]).to eq(%w[read write])
    expect(body["grant_types_supported"]).to include("authorization_code", "refresh_token")
    expect(body["code_challenge_methods_supported"]).to include("S256")
    expect(body["registration_endpoint"]).to end_with("/oauth/register")
  end

  it "advertises the protected resource metadata (RFC 9728) with configured resource_name" do
    get "/.well-known/oauth-protected-resource"
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["resource"]).to end_with("/mcp")
    expect(body["resource_name"]).to eq("Test MCP Server")
  end

  it "accepts an arbitrary resource path suffix" do
    get "/.well-known/oauth-protected-resource/mcp"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["resource_name"]).to eq("Test MCP Server")
  end
end
