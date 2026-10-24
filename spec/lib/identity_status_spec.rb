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
    allow(response).to receive(:body).and_return(body.is_a?(String) ? body : body.to_json)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:start) { |*args, **opts, &block| @start_options = opts; block.call(http) }
    allow(http).to receive(:request) { |req| @sent = req; response }
  end

  it "asks the IdP with the client's credentials, the user's sub, and for memberships" do
    stub_status(200, { sub: "42", active: true })
    standing = controller_class.identity_status(user)

    expect(standing).to be_active
    expect(standing).to eq(:active) # the pre-1.0 contract still compares
    expect(@sent["Authorization"]).to eq("Basic #{Base64.strict_encode64('cid:csecret')}")
    expect(URI.decode_www_form(@sent.body).to_h).to eq("sub" => "42", "include" => "memberships")
    expect(@start_options).to include(open_timeout: 3, read_timeout: 5)
  end

  it "carries memberships and the home account when Groundwork sends them" do
    stub_status(200, {
      sub: "42", active: true, home_account_id: "100",
      accounts: [ { id: "100", name: "FW", role: "admin" }, { id: "200", name: "Client", role: "member" }, "junk", { name: "no id" } ]
    })
    standing = controller_class.identity_status(user)

    expect(standing).to be_memberships
    expect(standing.accounts).to eq([ { "id" => "100", "name" => "FW", "role" => "admin" },
                                      { "id" => "200", "name" => "Client", "role" => "member" } ])
    expect(standing.home_account_id).to eq("100")
    expect(standing.mirror_account_column).to eq(:groundwork_account_id)
  end

  it "has no memberships when an older Groundwork answers active alone" do
    stub_status(200, { sub: "42", active: true })
    expect(controller_class.identity_status(user)).not_to be_memberships
  end

  it "reports inactive when the IdP says so, or has no record of the user (404)" do
    stub_status(200, { sub: "42", active: false })
    expect(controller_class.identity_status(user)).to be_inactive

    stub_status(404)
    expect(controller_class.identity_status(user)).to be_inactive
  end

  it "reports unknown, with a reason, for other statuses, bad bodies and network errors" do
    stub_status(401)
    expect(controller_class.identity_status(user)).to have_attributes(status: :unknown, reason: "HTTP 401")

    stub_status(500)
    expect(controller_class.identity_status(user)).to be_unknown

    stub_status(200, "<html>")
    expect(controller_class.identity_status(user)).to be_unknown

    stub_status(200, [ 1 ])
    expect(controller_class.identity_status(user)).to have_attributes(status: :unknown, reason: "unexpected response")

    allow(Net::HTTP).to receive(:start).and_raise(Net::OpenTimeout)
    expect(controller_class.identity_status(user)).to have_attributes(status: :unknown, reason: "Net::OpenTimeout")
  end

  it "returns nil (no check) when no user_status_url is configured" do
    expect(described_class.identity_status(user)).to be_nil
  end
end
