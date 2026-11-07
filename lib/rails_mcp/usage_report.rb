module RailsMcp
  # The daily tool-call counts a host sends Groundwork (POST
  # /oauth/mcp_usage), built from RailsMcp::ToolCall: one row per UTC day,
  # person, organisation, tool and outcome. People are named by their
  # Groundwork id (`identity_id`, the SSO `sub`) and organisations by the
  # mirrored Groundwork account id, never by email or name.
  #
  # Covers today and the DAYS - 1 days before it, and lists them in `days`:
  # Groundwork replaces whatever it holds for each listed day, so resending
  # is safe and a run that was missed is caught up by the next.
  class UsageReport
    class Failed < StandardError; end

    DAYS = 4

    def initialize(account_column: :groundwork_account_id, now: Time.current)
      # Interpolated into the pluck below, so only ever a plain column name.
      raise ArgumentError, "bad account column" unless account_column.to_s.match?(/\A[a-z_]+\z/)

      @account_column = account_column
      @today = now.utc.to_date
    end

    def days
      (0...DAYS).map { |i| @today - i }.reverse
    end

    def payload
      { server: RailsMcp.config.server_name, days: days.map(&:iso8601), rows: rows }
    end

    def rows
      counts = Hash.new { |h, k| h[k] = { calls: 0, duration_ms_total: 0 } }
      calls_in_window.each do |created_at, sub, account_ref, tool, outcome, duration|
        next if sub.blank?

        key = [ created_at.utc.to_date.iso8601, sub.to_s, integer_or_nil(account_ref), tool, outcome ]
        counts[key][:calls] += 1
        counts[key][:duration_ms_total] += duration.to_i
      end

      counts.map do |(day, sub, account_id, tool, outcome), sums|
        { day: day, sub: sub, account_id: account_id, tool: tool, outcome: outcome, **sums }
      end
    end

    private

    def calls_in_window
      RailsMcp::ToolCall
        .where(created_at: days.first.in_time_zone("UTC").beginning_of_day..)
        .joins(:user)
        .left_joins(:account)
        .pluck("mcp_tool_calls.created_at", "users.identity_id", "accounts.#{@account_column}",
               "mcp_tool_calls.tool_name", "mcp_tool_calls.outcome", "mcp_tool_calls.duration_ms")
    end

    def integer_or_nil(value)
      Integer(value.to_s, exception: false)
    end
  end
end
