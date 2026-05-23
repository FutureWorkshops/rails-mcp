require "rails_helper"

RSpec.describe "Dynamic client registration (RFC 7591)", type: :request do
  def post_register(body)
    post "/oauth/register", params: body.to_json, headers: { "CONTENT_TYPE" => "application/json" }
  end

  it "creates a public Doorkeeper::Application" do
    expect {
      post_register(
        client_name: "Claude",
        redirect_uris: [ "https://claude.example/cb" ],
        grant_types: %w[authorization_code refresh_token]
      )
    }.to change(Doorkeeper::Application, :count).by(1)

    expect(response).to have_http_status(:created)
    body = response.parsed_body
    expect(body).to include("client_id", "client_id_issued_at", "redirect_uris")
    expect(body["token_endpoint_auth_method"]).to eq("none")
    expect(Doorkeeper::Application.last).not_to be_confidential
  end

  it "rejects missing redirect_uris" do
    post_register(client_name: "Claude")
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["error"]).to eq("invalid_redirect_uri")
  end

  it "rejects bad grant_types" do
    post_register(redirect_uris: [ "https://example.com/cb" ], grant_types: %w[implicit])
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["error"]).to eq("invalid_client_metadata")
  end

  describe "redirect_uri validation" do
    it "rejects javascript: URIs" do
      post_register(redirect_uris: [ "javascript:alert(1)" ])
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_redirect_uri")
    end

    it "rejects data: URIs" do
      post_register(redirect_uris: [ "data:text/html,<script>fetch('/mcp')</script>" ])
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects mailto: URIs" do
      post_register(redirect_uris: [ "mailto:attacker@example.com" ])
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects file: URIs" do
      post_register(redirect_uris: [ "file:///etc/passwd" ])
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects URIs with userinfo (credentials in URL)" do
      post_register(redirect_uris: [ "https://attacker@example.com/cb" ])
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects URIs with a fragment" do
      post_register(redirect_uris: [ "https://example.com/cb#injected" ])
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects URIs with no host" do
      post_register(redirect_uris: [ "https:///cb" ])
      expect(response).to have_http_status(:bad_request)
    end

    it "accepts plain http://localhost in test/development" do
      post_register(redirect_uris: [ "http://localhost:54321/cb" ])
      expect(response).to have_http_status(:created)
    end

    it "accepts http://127.0.0.1 in test/development" do
      post_register(redirect_uris: [ "http://127.0.0.1:54321/cb" ])
      expect(response).to have_http_status(:created)
    end

    it "rejects plain http to a non-loopback host" do
      post_register(redirect_uris: [ "http://example.com/cb" ])
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects loopback http when Rails.env is production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      post_register(redirect_uris: [ "http://localhost:54321/cb" ])
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an oversized client_name" do
      post_register(
        redirect_uris: [ "https://example.com/cb" ],
        client_name: "x" * 1000
      )
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_client_metadata")
    end
  end
end
