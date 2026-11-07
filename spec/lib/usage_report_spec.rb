require "net/http"
require "rails_helper"

RSpec.describe RailsMcp::UsageReport do
  let(:now) { Time.utc(2026, 11, 7, 12) }
  let(:account) { RailsMcp::Account.create!(name: "Acme", groundwork_account_id: "100") }
  let(:jo) { account.users.create!(email: "jo@example.com", identity_id: "42") }
  let(:sam) { RailsMcp::Account.create!(name: "Solo").users.create!(email: "sam@example.com", identity_id: "43") }

  def call!(user, tool:, outcome: "ok", at: now, duration: 100)
    RailsMcp::ToolCall.create!(user: user, account: user.account, tool_name: tool, outcome: outcome,
                               duration_ms: duration, created_at: at)
  end

  before { RailsMcp.configure { |c| c.server_name = "gmail-mcp-rails" } }

  it "counts calls per day, person, organisation, tool and outcome, by Groundwork ids" do
    call!(jo, tool: "list-messages", duration: 100)
    call!(jo, tool: "list-messages", duration: 300)
    call!(jo, tool: "send-message", outcome: "error", at: now - 1.day)
    call!(sam, tool: "list-messages")
    call!(jo, tool: "list-messages", at: now - 4.days) # outside the window

    payload = described_class.new(now: now).payload

    expect(payload[:server]).to eq("gmail-mcp-rails")
    expect(payload[:days]).to eq(%w[2026-11-04 2026-11-05 2026-11-06 2026-11-07])
    expect(payload[:rows]).to contain_exactly(
      { day: "2026-11-07", sub: "42", account_id: 100, tool: "list-messages", outcome: "ok", calls: 2, duration_ms_total: 400 },
      { day: "2026-11-06", sub: "42", account_id: 100, tool: "send-message", outcome: "error", calls: 1, duration_ms_total: 100 },
      { day: "2026-11-07", sub: "43", account_id: nil, tool: "list-messages", outcome: "ok", calls: 1, duration_ms_total: 100 }
    )
    expect(payload.to_json).not_to include("jo@example.com")
  end

  it "refuses an account column that isn't a plain name" do
    expect { described_class.new(account_column: "id; drop table users") }.to raise_error(ArgumentError)
  end

  describe "sending it (OauthClientController.report_usage)" do
    let(:controller_class) do
      Class.new(RailsMcp::OauthClientController) do
        def self.client_id = "cid"
        def self.client_secret = "csecret"
        def self.user_status_url = "https://idp.example.test/oauth/user_status"
      end
    end

    def stub_response(status, body = "{}")
      response = Net::HTTPResponse::CODE_TO_OBJ[status.to_s].new("1.1", status.to_s, "")
      allow(response).to receive(:body).and_return(body)
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:start) { |host, *_args, **opts, &block| @host = host; @options = opts; block.call(http) }
      allow(http).to receive(:request) { |req| @sent = req; response }
    end

    it "posts the payload to the IdP's usage endpoint with the client's credentials" do
      call!(jo, tool: "list-messages")
      stub_response(200, { accepted: 1 }.to_json)

      expect(controller_class.report_usage(now: now)).to eq("accepted" => 1)
      expect(@host).to eq("idp.example.test")
      expect(@sent.path).to eq("/oauth/mcp_usage")
      expect(@sent["Authorization"]).to eq("Basic #{Base64.strict_encode64('cid:csecret')}")
      expect(@sent["Content-Type"]).to eq("application/json")
      expect(JSON.parse(@sent.body)["rows"].sole).to include("sub" => "42", "tool" => "list-messages")
      expect(@options).to include(use_ssl: true, open_timeout: 3, read_timeout: 5)
    end

    it "raises when the IdP refuses it, or there is nowhere to send it" do
      stub_response(401)
      expect { controller_class.report_usage(now: now) }.to raise_error(RailsMcp::UsageReport::Failed, "HTTP 401")

      expect(RailsMcp::OauthClientController.usage_report_url).to be_nil
      expect { RailsMcp::OauthClientController.report_usage }.to raise_error(RailsMcp::UsageReport::Failed)
    end
  end
end
