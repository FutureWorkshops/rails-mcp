module RailsMcp
  # Daily: sends the last few days' tool-call counts to Groundwork
  # (RailsMcp::UsageReport, through config.usage_reporter), then deletes
  # RailsMcp::ToolCall rows older than config.tool_call_retention. A failed
  # send is reported and the purge still runs; the next run resends the same
  # days. Hosts schedule it in config/recurring.yml:
  #
  #   rails_mcp_usage_report:
  #     class: RailsMcp::UsageReportJob
  #     schedule: every day at 2:30am
  class UsageReportJob < ActiveJob::Base
    queue_as :default

    def perform
      report
      RailsMcp::ToolCall.where(created_at: ...RailsMcp.config.tool_call_retention.ago).in_batches(of: 5_000).delete_all
    end

    private

    def report
      reporter = RailsMcp.config.usage_reporter
      reporter&.call
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { rails_mcp: "usage report not sent" })
    end
  end
end
