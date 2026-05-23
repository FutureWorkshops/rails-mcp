require "rails_helper"

class GreetTool < RailsMcp::BaseTool
  def self.tool_name = "list-greetings"
  def self.description = "Returns a greeting"
  def self.input_schema = { type: "object", properties: { name: { type: "string" } } }

  def call(name: "world")
    "Hello, #{name}!"
  end
end

class ExplodingTool < RailsMcp::BaseTool
  class CustomError < StandardError; end
  def self.tool_name = "explode"
  def self.description = ""
  def self.input_schema = { type: "object", properties: {} }
  def call(**)
    raise CustomError, "kaboom"
  end
end

RSpec.describe "MCP JSON-RPC dispatcher", type: :request do
  before do
    RailsMcp.configure do |c|
      c.server_name = "test-mcp"
      c.server_version = "9.9.9"
    end
    RailsMcp::Registry.register(GreetTool)
    RailsMcp::Registry.register(ExplodingTool)
  end

  describe "without an access token" do
    it "responds with -32001 and RFC 9728 WWW-Authenticate" do
      post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "initialize" }.to_json,
                   headers: { "CONTENT_TYPE" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["code"]).to eq(-32001)
      expect(response.headers["WWW-Authenticate"]).to include("resource_metadata=")
      expect(response.headers["WWW-Authenticate"]).to include("/.well-known/oauth-protected-resource")
    end
  end

  context "with a valid access token" do
    let(:user)  { make_user }
    let(:token) { issue_access_token_for(user) }

    it "initialize returns configured serverInfo" do
      mcp_call({ jsonrpc: "2.0", id: 1, method: "initialize" }, token: token)
      result = response.parsed_body["result"]
      expect(result["protocolVersion"]).to eq("2024-11-05")
      expect(result["serverInfo"]).to eq("name" => "test-mcp", "version" => "9.9.9")
    end

    it "tools/list returns registered tools with annotations" do
      mcp_call({ jsonrpc: "2.0", id: 2, method: "tools/list" }, token: token)
      tools = response.parsed_body["result"]["tools"]
      expect(tools.map { |t| t["name"] }).to contain_exactly("list-greetings", "explode")
      greet = tools.find { |t| t["name"] == "list-greetings" }
      expect(greet["annotations"]["readOnlyHint"]).to be true
    end

    it "tools/call invokes the tool and returns its text result" do
      mcp_call({ jsonrpc: "2.0", id: 3, method: "tools/call",
                 params: { name: "list-greetings", arguments: { name: "Matt" } } }, token: token)
      content = response.parsed_body["result"]["content"].first
      expect(content["text"]).to eq("Hello, Matt!")
      expect(response.parsed_body["result"]["isError"]).to be false
    end

    it "tools/call with an unknown argument returns isError + hint" do
      mcp_call({ jsonrpc: "2.0", id: 4, method: "tools/call",
                 params: { name: "list-greetings", arguments: { bogus: 1 } } }, token: token)
      result = response.parsed_body["result"]
      expect(result["isError"]).to be true
      expect(result["content"].first["text"]).to include("Unknown argument")
    end

    it "tools/call for an unknown tool returns -32601" do
      mcp_call({ jsonrpc: "2.0", id: 5, method: "tools/call",
                 params: { name: "nope" } }, token: token)
      expect(response.parsed_body["error"]["code"]).to eq(-32601)
    end

    it "calls tool_error_handler when set" do
      RailsMcp.config.tool_error_handler = ->(error, **) {
        "Handled: #{error.class.name}: #{error.message}" if error.is_a?(ExplodingTool::CustomError)
      }
      mcp_call({ jsonrpc: "2.0", id: 6, method: "tools/call",
                 params: { name: "explode" } }, token: token)
      content = response.parsed_body["result"]["content"].first
      expect(content["text"]).to start_with("Handled: ExplodingTool::CustomError: kaboom")
      expect(response.parsed_body["result"]["isError"]).to be true
    end

    it "falls through to default error text when no handler matches" do
      mcp_call({ jsonrpc: "2.0", id: 7, method: "tools/call",
                 params: { name: "explode" } }, token: token)
      content = response.parsed_body["result"]["content"].first
      expect(content["text"]).to eq("Error: kaboom")
    end

    it "dispatches a batched JSON-RPC array" do
      mcp_call([
        { jsonrpc: "2.0", id: 10, method: "initialize" },
        { jsonrpc: "2.0", id: 11, method: "tools/list" }
      ], token: token)
      results = response.parsed_body
      expect(results.size).to eq(2)
      expect(results.map { |r| r["id"] }).to eq([ 10, 11 ])
    end

    it "swallows notifications (no id, notifications/* method) with 204" do
      mcp_call({ jsonrpc: "2.0", method: "notifications/initialized" }, token: token)
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "scope enforcement" do
    before do
      RailsMcp::Registry.register(GreetTool)
      RailsMcp::Registry.register(ExplodingTool)
    end

    let(:user) { make_user }

    # GreetTool's name starts with `list-` so its readOnlyHint is true; ExplodingTool
    # has no read-only prefix so it requires the `write` scope.
    let(:read_only_token)  { issue_access_token_for(user, scopes: "read") }
    let(:write_only_token) { issue_access_token_for(user, scopes: "write") }

    it "allows a read-only token to call a read-only tool" do
      mcp_call({ jsonrpc: "2.0", id: 100, method: "tools/call",
                 params: { name: "list-greetings", arguments: {} } }, token: read_only_token)
      expect(response.parsed_body["result"]["isError"]).to be false
    end

    it "denies a read-only token from calling a write tool" do
      mcp_call({ jsonrpc: "2.0", id: 101, method: "tools/call",
                 params: { name: "explode" } }, token: read_only_token)
      result = response.parsed_body["result"]
      expect(result["isError"]).to be true
      expect(result["content"].first["text"]).to include("Insufficient OAuth scope")
      expect(result["content"].first["text"]).to include("requires 'write'")
    end

    it "allows a write-only token to reach a write tool (scope check passes; tool itself can still fail)" do
      RailsMcp.config.tool_error_handler = ->(error, **) { "handled" }
      mcp_call({ jsonrpc: "2.0", id: 102, method: "tools/call",
                 params: { name: "explode" } }, token: write_only_token)
      expect(response.parsed_body["result"]["content"].first["text"]).to eq("handled")
    end

    it "denies a write-only token from calling a read-only tool" do
      mcp_call({ jsonrpc: "2.0", id: 103, method: "tools/call",
                 params: { name: "list-greetings" } }, token: write_only_token)
      result = response.parsed_body["result"]
      expect(result["isError"]).to be true
      expect(result["content"].first["text"]).to include("requires 'read'")
    end
  end
end
