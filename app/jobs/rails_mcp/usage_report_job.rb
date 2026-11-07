module RailsMcp
  # Daily: sends the last few days' tool-call counts to Groundwork
  # (RailsMcp::UsageReport, through config.usage_reporter), then deletes
  # RailsMcp::ToolCall rows older than config.tool_call_retention. A failed
  # send is reported and the purge still runs; the next run resends the same
  # days.
  #
  # Hosts on Heroku without a Solid Queue worker run it from Heroku Scheduler
  # as `bin/rails rails_mcp:daily` (script/heroku-schedule-daily sets that
  # up). Where Solid Queue runs, config/recurring.yml schedules it:
  #
  #   rails_mcp_usage_report:
  #     class: RailsMcp::UsageReportJob
  #     schedule: every day at 2:30am
  #
  # Returns :sent, :failed or :skipped (no reporter configured).
  class UsageReportJob < ActiveJob::Base
    queue_as :default

    def perform
      outcome = report
      RailsMcp::ToolCall.where(created_at: ...RailsMcp.config.tool_call_retention.ago).in_batches(of: 5_000).delete_all
      outcome
    end

    private

    def report
      reporter = RailsMcp.config.usage_reporter
      return :skipped unless reporter

      reporter.call
      :sent
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { rails_mcp: "usage report not sent" })
      :failed
    end
  end
end
