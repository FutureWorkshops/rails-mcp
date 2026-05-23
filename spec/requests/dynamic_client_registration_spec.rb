require "rails_helper"

RSpec.describe "Dynamic client registration (RFC 7591)", type: :request do
  it "creates a public Doorkeeper::Application" do
    expect {
      post "/oauth/register",
        params: { client_name: "Claude", redirect_uris: [ "https://claude.example/cb" ], grant_types: %w[authorization_code refresh_token] }.to_json,
        headers: { "CONTENT_TYPE" => "application/json" }
    }.to change(Doorkeeper::Application, :count).by(1)

    expect(response).to have_http_status(:created)
    body = response.parsed_body
    expect(body).to include("client_id", "client_id_issued_at", "redirect_uris")
    expect(body["token_endpoint_auth_method"]).to eq("none")
    expect(Doorkeeper::Application.last).not_to be_confidential
  end

  it "rejects missing redirect_uris" do
    post "/oauth/register",
      params: { client_name: "Claude" }.to_json,
      headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["error"]).to eq("invalid_redirect_uri")
  end

  it "rejects bad grant_types" do
    post "/oauth/register",
      params: { redirect_uris: [ "https://example/cb" ], grant_types: %w[implicit] }.to_json,
      headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["error"]).to eq("invalid_client_metadata")
  end
end
