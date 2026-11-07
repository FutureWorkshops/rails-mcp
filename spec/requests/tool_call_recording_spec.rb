require "rails_helper"

class RecordedReadTool < RailsMcp::BaseTool
  def self.tool_name = "list-things"
  def self.description = ""
  def self.input_schema = { type: "object", properties: { secret: { type: "string" } } }
  def call(secret: nil) = "ok"
end

class RecordedWriteTool < RailsMcp::BaseTool
  class Boom < StandardError; end
  def self.tool_name = "create-thing"
  def self.description = ""
  def self.input_schema = { type: "object", properties: {} }
  def call(**) = raise(Boom, "kaboom")
end

RSpec.describe "Recording MCP tool calls", type: :request do
  let(:user) { make_user }

  before do
    RailsMcp::Registry.register(RecordedReadTool)
    RailsMcp::Registry.register(RecordedWriteTool)
  end

  def call_tool(name, arguments = {}, scopes: "read write")
    mcp_call({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } },
             token: issue_access_token_for(user, scopes: scopes))
  end

  it "records a successful call, never its arguments" do
    call_tool("list-things", { secret: "the content of an email" })

    call = RailsMcp::ToolCall.sole
    expect(call).to have_attributes(user_id: user.id, account_id: user.account_id, tool_name: "list-things",
                                    read_only: true, outcome: "ok", error_class: nil, client_name: "Test")
    expect(call.duration_ms).to be >= 0
    expect(call.attributes.values.map(&:to_s).join).not_to include("the content of an email")
  end

  it "records a failure with its class" do
    call_tool("create-thing")
    expect(RailsMcp::ToolCall.sole).to have_attributes(outcome: "error", error_class: "RecordedWriteTool::Boom", read_only: false)
  end

  it "records a call refused for want of a scope as denied" do
    call_tool("create-thing", scopes: "read")
    expect(RailsMcp::ToolCall.sole).to have_attributes(outcome: "denied", error_class: nil)
  end

  it "records unknown arguments as an error" do
    call_tool("list-things", { nope: 1 })
    expect(RailsMcp::ToolCall.sole.outcome).to eq("error")
  end

  it "doesn't record an unknown tool name, or tools/list" do
    call_tool("anything-the-client-likes")
    mcp_call({ jsonrpc: "2.0", id: 2, method: "tools/list" }, token: issue_access_token_for(user))
    expect(RailsMcp::ToolCall.count).to eq(0)
  end

  it "doesn't record when switched off" do
    RailsMcp.configure { |c| c.record_tool_calls = false }
    call_tool("list-things")
    expect(RailsMcp::ToolCall.count).to eq(0)
  end

  it "never fails the call when recording does" do
    allow(RailsMcp::ToolCall).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "db down")
    expect(Rails.error).to receive(:report).with(an_instance_of(ActiveRecord::StatementInvalid), hash_including(handled: true))

    call_tool("list-things")

    expect(response.parsed_body.dig("result", "isError")).to be(false)
    expect(response.parsed_body.dig("result", "content", 0, "text")).to eq("ok")
  end
end
