require "rails_helper"

RSpec.describe RailsMcp::ClientTrust do
  it "trusts claude.ai, claude.com, their subdomains and loopback" do
    expect(described_class.trusted?("https://claude.ai/api/mcp/auth_callback")).to be(true)
    expect(described_class.trusted?("https://app.claude.com/cb")).to be(true)
    expect(described_class.trusted?("http://127.0.0.1:6274/oauth/callback")).to be(true)
    expect(described_class.trusted?("http://localhost:3000/cb")).to be(true)
  end

  it "does not trust look-alike or unknown hosts" do
    expect(described_class.trusted?("https://evil.example/cb")).to be(false)
    expect(described_class.trusted?("https://notclaude.ai/cb")).to be(false)
    expect(described_class.trusted?("https://claude.ai.evil.example/cb")).to be(false)
    expect(described_class.trusted?("not a uri")).to be(false)
  end

  it "reports the redirect host" do
    expect(described_class.redirect_host("https://Claude.AI/cb")).to eq("claude.ai")
  end
end
