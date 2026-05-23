require "rails_helper"

RSpec.describe "Rack::Attack defaults", type: :request do
  before do
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.reset!
    Rack::Attack.throttles.clear
    RailsMcp::RackAttackDefaults.apply!(
      register_per_ip:        { limit: 2, period: 60 },
      mcp_per_token:          { limit: 2, period: 60 },
      mcp_per_ip:             { limit: 100, period: 60 },
      invitations_per_user:   { limit: 2, period: 60 }
    )
  end

  after do
    Rack::Attack.throttles.clear
  end

  describe "POST /oauth/register" do
    it "throttles after the configured limit" do
      2.times do |i|
        post "/oauth/register",
          params: { redirect_uris: [ "https://c#{i}.example.com/cb" ] }.to_json,
          headers: { "CONTENT_TYPE" => "application/json", "REMOTE_ADDR" => "1.2.3.4" }
        expect(response).to have_http_status(:created)
      end

      post "/oauth/register",
        params: { redirect_uris: [ "https://c.example.com/cb" ] }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "REMOTE_ADDR" => "1.2.3.4" }
      expect(response).to have_http_status(:too_many_requests)
    end

    it "isolates throttle buckets per IP" do
      2.times do |i|
        post "/oauth/register",
          params: { redirect_uris: [ "https://c#{i}.example.com/cb" ] }.to_json,
          headers: { "CONTENT_TYPE" => "application/json", "REMOTE_ADDR" => "1.1.1.1" }
        expect(response).to have_http_status(:created)
      end

      post "/oauth/register",
        params: { redirect_uris: [ "https://other.example.com/cb" ] }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "REMOTE_ADDR" => "9.9.9.9" }
      expect(response).to have_http_status(:created)
    end
  end

  describe "POST /mcp throttling by bearer token" do
    let(:user) do
      account = RailsMcp::Account.create!(name: "Acme")
      account.users.create!(email: "u@example.com", identity_id: "id-1")
    end

    let(:token) do
      app = Doorkeeper::Application.create!(name: "T", redirect_uri: "https://example.com/cb", scopes: "read write", confidential: false)
      Doorkeeper::AccessToken.create!(application_id: app.id, resource_owner_id: user.id, scopes: "read write", expires_in: 3600, use_refresh_token: false)
    end

    it "throttles to the per-token limit" do
      body = { jsonrpc: "2.0", id: 1, method: "initialize" }.to_json
      headers = { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{token.token}" }

      2.times { post "/mcp", params: body, headers: headers }
      post "/mcp", params: body, headers: headers
      expect(response).to have_http_status(:too_many_requests)
    end
  end
end
