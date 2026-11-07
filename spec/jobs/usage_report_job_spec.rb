require "rails_helper"

RSpec.describe RailsMcp::UsageReportJob do
  let(:user) { RailsMcp::Account.create!(name: "Acme").users.create!(email: "jo@example.com", identity_id: "42") }

  def call_at(time)
    RailsMcp::ToolCall.create!(user: user, account: user.account, tool_name: "list-things", outcome: "ok", created_at: time)
  end

  it "sends the report, then purges rows past the retention" do
    sent = []
    RailsMcp.configure { |c| c.usage_reporter = -> { sent << :report } }
    old = call_at(91.days.ago)
    recent = call_at(1.hour.ago)

    described_class.perform_now

    expect(sent).to eq([ :report ])
    expect(RailsMcp::ToolCall.pluck(:id)).to eq([ recent.id ])
    expect(RailsMcp::ToolCall.exists?(old.id)).to be(false)
  end

  it "reports a failed send and still purges" do
    RailsMcp.configure { |c| c.usage_reporter = -> { raise RailsMcp::UsageReport::Failed, "HTTP 503" } }
    call_at(91.days.ago)
    expect(Rails.error).to receive(:report).with(an_instance_of(RailsMcp::UsageReport::Failed), hash_including(handled: true))

    described_class.perform_now

    expect(RailsMcp::ToolCall.count).to eq(0)
  end

  it "only purges when no reporter is configured" do
    call_at(91.days.ago)
    expect { described_class.perform_now }.to change(RailsMcp::ToolCall, :count).from(1).to(0)
  end
end
