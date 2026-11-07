require "rails_helper"
require "rake"

RSpec.describe "rails_mcp:daily" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "rails_mcp:daily" }
  end

  let(:task) { Rake::Task["rails_mcp:daily"] }
  let(:user) { RailsMcp::Account.create!(name: "Acme").users.create!(email: "jo@example.com", identity_id: "42") }

  it "sends the report and purges old calls" do
    sent = []
    RailsMcp.configure { |c| c.usage_reporter = -> { sent << :report } }
    RailsMcp::ToolCall.create!(user: user, tool_name: "list-things", outcome: "ok", created_at: 91.days.ago)

    expect { task.execute }.to output(/Usage report sent/).to_stdout

    expect(sent).to eq([ :report ])
    expect(RailsMcp::ToolCall.count).to eq(0)
  end

  it "exits non-zero when the report fails, after purging" do
    RailsMcp.configure { |c| c.usage_reporter = -> { raise RailsMcp::UsageReport::Failed, "HTTP 401" } }
    RailsMcp::ToolCall.create!(user: user, tool_name: "list-things", outcome: "ok", created_at: 91.days.ago)

    expect { task.execute }.to raise_error(SystemExit).and output(/usage report failed/).to_stderr
    expect(RailsMcp::ToolCall.count).to eq(0)
  end

  it "warns when no reporter is configured" do
    expect { task.execute }.to output(/No usage_reporter configured/).to_stderr
  end
end
