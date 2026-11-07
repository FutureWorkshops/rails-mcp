module RailsMcp
  # One MCP tools/call, recorded by McpController#handle_tool_call: who, which
  # tool, how it went and how long it took. Never the arguments or the result,
  # which carry the user's own content (emails, invoices, HR records).
  #
  # Kept for `RailsMcp.config.tool_call_retention` (90 days) and summarised
  # daily to Groundwork by RailsMcp::UsageReportJob.
  class ToolCall < ApplicationRecord
    self.table_name = "mcp_tool_calls"

    OUTCOMES = %w[ok error denied].freeze

    belongs_to :user, class_name: "RailsMcp::User"
    belongs_to :account, class_name: "RailsMcp::Account", optional: true

    validates :tool_name, presence: true
    validates :outcome, inclusion: { in: OUTCOMES }
  end
end
