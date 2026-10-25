require "rails_helper"

RSpec.describe "Dynamic client registration (RFC 7591)", type: :request do
  def post_register(body)
    post "/oauth/register", params: body.to_json, headers: { "CONTENT_TYPE" => "application/json" }
  end

  it "creates a public Doorkeeper::Application" do
    expect {
      post_register(
        client_name: "Claude",
        redirect_uris: [ "https://claude.ai/api/mcp/auth_callback" ],
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
    post_register(redirect_uris: [ "https://claude.ai/api/mcp/auth_callback" ], grant_types: %w[implicit])
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
      RailsMcp.config.allowed_redirect_hosts = %w[example.com]
      post_register(redirect_uris: [ "https://attacker@example.com/cb" ])
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects URIs with a fragment" do
      RailsMcp.config.allowed_redirect_hosts = %w[example.com]
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

    it "accepts loopback http in production too, where Claude Code listens" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      post_register(redirect_uris: [ "http://localhost:54321/cb" ])
      expect(response).to have_http_status(:created)
    end

    it "rejects plain http to a non-loopback host in production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      post_register(redirect_uris: [ "http://claude.ai/api/mcp/auth_callback" ])
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an oversized client_name" do
      post_register(
        redirect_uris: [ "https://claude.ai/api/mcp/auth_callback" ],
        client_name: "x" * 1000
      )
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_client_metadata")
    end
  end

  describe "redirect URI allowlist (ENG-01)" do
    around do |example|
      original = ENV["OAUTH_DCR_ALLOWED_REDIRECT_HOSTS"]
      ENV.delete("OAUTH_DCR_ALLOWED_REDIRECT_HOSTS")
      example.run
    ensure
      ENV["OAUTH_DCR_ALLOWED_REDIRECT_HOSTS"] = original
    end

    it "accepts both of Claude's connector callbacks" do
      post_register(redirect_uris: %w[https://claude.ai/api/mcp/auth_callback https://claude.com/api/mcp/auth_callback])
      expect(response).to have_http_status(:created)
    end

    it "accepts loopback on any port, including IPv6" do
      post_register(redirect_uris: [ "http://127.0.0.1:6274/oauth/callback", "http://[::1]:8080/cb" ])
      expect(response).to have_http_status(:created)
    end

    it "refuses the attacker's own server, whatever the client calls itself" do
      expect {
        post_register(client_name: "Claude", redirect_uris: [ "https://attacker.example/cb" ])
      }.not_to change(Doorkeeper::Application, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_redirect_uri")
    end

    it "refuses look-alikes of Claude's callback" do
      [
        "https://claude.ai.attacker.example/api/mcp/auth_callback",
        "https://claude.ai/api/mcp/auth_callback/../../evil",
        "https://claude.ai/somewhere-else",
        "https://claude.ai:8443/api/mcp/auth_callback",
        "https://169.254.169.254/cb",
        "https://localhost/cb"
      ].each do |uri|
        post_register(redirect_uris: [ uri ])
        expect(response).to have_http_status(:bad_request), uri
      end
    end

    it "refuses a list where only one entry is bad" do
      post_register(redirect_uris: [ "https://claude.ai/api/mcp/auth_callback", "https://attacker.example/cb" ])
      expect(response).to have_http_status(:bad_request)
    end

    it "accepts an https host the operator lists in OAUTH_DCR_ALLOWED_REDIRECT_HOSTS" do
      ENV["OAUTH_DCR_ALLOWED_REDIRECT_HOSTS"] = " grok.com , connector.example "
      post_register(client_name: "Grok", redirect_uris: [ "https://grok.com/oauth/callback" ])
      expect(response).to have_http_status(:created)

      post_register(redirect_uris: [ "http://grok.com/oauth/callback" ])
      expect(response).to have_http_status(:bad_request)

      post_register(redirect_uris: [ "https://evil.grok.com/oauth/callback" ])
      expect(response).to have_http_status(:bad_request)
    end

    it "lets config.allowed_redirect_hosts take the place of the environment variable" do
      ENV["OAUTH_DCR_ALLOWED_REDIRECT_HOSTS"] = "other.example"
      RailsMcp.config.allowed_redirect_hosts = %w[Grok.com]
      post_register(redirect_uris: [ "https://grok.com/oauth/callback" ])
      expect(response).to have_http_status(:created)

      post_register(redirect_uris: [ "https://other.example/cb" ])
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "bounds on the request (ENG-08)" do
    it "answers 400, not 500, when the body is a JSON array or a bare value" do
      [ "[]", "[1,2]", "42", "\"x\"", "null" ].each do |body|
        post "/oauth/register", params: body, headers: { "CONTENT_TYPE" => "application/json" }
        expect(response).to have_http_status(:bad_request), body
        expect(response.parsed_body["error"]).to eq("invalid_client_metadata")
      end
    end

    it "answers 400 for a body that isn't JSON" do
      post "/oauth/register", params: "{nope", headers: { "CONTENT_TYPE" => "application/json" }
      expect(response).to have_http_status(:bad_request)
    end

    it "refuses non-string redirect_uris and non-string client names without a 500" do
      post_register(redirect_uris: [ { "x" => 1 } ])
      expect(response).to have_http_status(:bad_request)

      post_register(redirect_uris: [ "https://claude.ai/api/mcp/auth_callback" ], client_name: { "a" => 1 }, scope: [ "read" ])
      expect(response).to have_http_status(:created)
      expect(Doorkeeper::Application.last.name).to eq("MCP client")
    end

    it "caps the number of redirect URIs" do
      uris = (1..6).map { |i| "http://127.0.0.1:#{3000 + i}/cb" }
      post_register(redirect_uris: uris)
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error_description"]).to include("at most 5")

      post_register(redirect_uris: uris.first(5))
      expect(response).to have_http_status(:created)
    end

    it "caps the length of each redirect URI" do
      post_register(redirect_uris: [ "http://127.0.0.1:3000/#{'a' * 2100}" ])
      expect(response).to have_http_status(:bad_request)
    end
  end
end
