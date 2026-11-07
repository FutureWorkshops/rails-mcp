namespace :rails_mcp do
  desc "Offboard a user: revoke all their MCP OAuth tokens and delete their provider connections. Usage: rails rails_mcp:revoke_user[email]"
  task :revoke_user, [ :email ] => :environment do |_task, args|
    email = args[:email].to_s.strip.downcase
    abort "Usage: rails rails_mcp:revoke_user[email]" if email.empty?

    user = RailsMcp::User.find_by(email: email)
    abort "No user with email #{email}" unless user

    tokens = Doorkeeper::AccessToken.where(resource_owner_id: user.id, revoked_at: nil).count
    RailsMcp::RefreshTokenPolicy.revoke_all_for_owner!(user.id)
    connections = user.connections.destroy_all.size

    puts "Revoked #{tokens} token(s) and deleted #{connections} connection(s) for #{email}."
  end

  desc "MCP tool calls on this host by tool and outcome. Usage: rails rails_mcp:usage[days] (default 7)"
  task :usage, [ :days ] => :environment do |_task, args|
    days = (args[:days].presence || 7).to_i
    calls = RailsMcp::ToolCall.where(created_at: days.days.ago..)
    puts "MCP tool calls, last #{days} days: #{calls.count} by #{calls.distinct.count(:user_id)} people"
    calls.group(:tool_name, :outcome).count.sort_by { |(tool, outcome), n| [ -n, tool, outcome ] }.each do |(tool, outcome), n|
      puts format("  %-40s %-7s %6d", tool, outcome, n)
    end
  end

  # The one command Heroku Scheduler runs, so new daily work joins here
  # without anyone editing the Scheduler job. Exits non-zero when the report
  # fails, which Scheduler's logs show; the purge has still run.
  desc "The engine's daily housekeeping, for Heroku Scheduler: send the usage report to Groundwork and purge old tool calls"
  task daily: :environment do
    case RailsMcp::UsageReportJob.perform_now
    when :sent then puts "Usage report sent."
    when :skipped then warn "No usage_reporter configured, so no usage report was sent (see RailsMcp.config.usage_reporter)."
    when :failed then abort "The usage report failed; it is reported through Rails.error and will be resent tomorrow."
    end
  end

  desc "Send the usage report to Groundwork now, as the daily RailsMcp::UsageReportJob does"
  task push_usage: :environment do
    reporter = RailsMcp.config.usage_reporter
    abort "No usage_reporter configured (see RailsMcp.config.usage_reporter)." unless reporter

    puts reporter.call.inspect
  end
end
