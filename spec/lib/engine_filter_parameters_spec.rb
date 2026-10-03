require "rails_helper"

RSpec.describe "RailsMcp::Engine filter_parameters" do
  it "auto-appends OAuth secrets to the host's filter_parameters list" do
    filter = Rails.application.config.filter_parameters

    RailsMcp::Engine::OAUTH_FILTER_PARAMETERS.each do |key|
      expect(filter).to include(key), "expected #{key.inspect} to be in filter_parameters"
    end
  end

  it "redacts request parameters whose key matches the engine's OAuth list" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      "access_token"  => "SECRET-ACCESS",
      "refresh_token" => "SECRET-REFRESH",
      "code"          => "auth-code-123",
      "name"          => "Alice"
    )

    expect(filtered["access_token"]).to eq("[FILTERED]")
    expect(filtered["refresh_token"]).to eq("[FILTERED]")
    expect(filtered["code"]).to eq("[FILTERED]")
    expect(filtered["name"]).to eq("Alice")
  end

  it "redacts MCP tool arguments, including the wrapped copy" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      "method" => "tools/call",
      "params" => { "name" => "create-draft", "arguments" => { "body" => "secret email" } },
      "mcp"    => { "params" => { "arguments" => { "body" => "secret email" } } }
    )

    expect(filtered.dig("params", "arguments")).to eq("[FILTERED]")
    expect(filtered.dig("mcp", "params", "arguments")).to eq("[FILTERED]")
    expect(filtered.dig("params", "name")).to eq("create-draft")
  end
end
