require "net/http"
require "rails_helper"

RSpec.describe RailsMcp::OauthClientController do
  let(:user) { RailsMcp::Account.create!(name: "A").users.create!(email: "u@example.com", identity_id: "42") }
  let(:controller_class) do
    Class.new(described_class) do
      def self.client_id = "cid"
      def self.client_secret = "csecret"
      def self.user_status_url = "https://idp.example.test/oauth/user_status"
    end
  end

  def stub_status(status, body = nil)
    response = Net::HTTPResponse::CODE_TO_OBJ[status.to_s].new("1.1", status.to_s, "")
    allow(response).to receive(:body).and_return(body.to_json)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:start).and_yield(http).and_return(response)
    allow(http).to receive(:request) { |req| @sent = req; response }
  end

  it "asks the IdP with the client's credentials and the user's sub" do
    stub_status(200, { sub: "42", active: true })
    expect(controller_class.identity_status(user)).to eq(:active)
    expect(@sent["Authorization"]).to eq("Basic #{Base64.strict_encode64('cid:csecret')}")
    expect(URI.decode_www_form(@sent.body).to_h).to eq("sub" => "42")
  end

  it "reports :inactive when the IdP says so" do
    stub_status(200, { sub: "42", active: false })
    expect(controller_class.identity_status(user)).to eq(:inactive)
  end

  it "reports :unknown for errors, 404s or no endpoint, so refreshes aren't blocked" do
    stub_status(404)
    expect(controller_class.identity_status(user)).to eq(:unknown)

    allow(Net::HTTP).to receive(:start).and_raise(Net::OpenTimeout)
    expect(controller_class.identity_status(user)).to eq(:unknown)

    expect(described_class.identity_status(user)).to eq(:unknown)
  end
end
