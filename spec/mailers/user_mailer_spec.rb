require "rails_helper"

RSpec.describe RailsMcp::UserMailer, type: :mailer do
  let(:account) { RailsMcp::Account.create!(name: "Acme") }
  let(:inviter) { account.users.create!(email: "host@example.com", identity_id: "host", name: "Host Person") }
  let(:invitation) { account.invitations.create!(email: "guest@example.com", invited_by: inviter) }

  before do
    RailsMcp.configure do |c|
      c.display_name = "Acme MCP"
      c.mailer_from = "Acme MCP <no-reply@acme.example>"
    end
  end

  it "uses display_name in subject and from" do
    mail = described_class.invite_email(invitation_id: invitation.id)
    expect(mail.subject).to eq("Host Person invited you to join Acme on Acme MCP")
    expect(mail.from).to eq([ "no-reply@acme.example" ])
    expect(mail.to).to eq([ "guest@example.com" ])
  end

  it "links to the invitation URL in both bodies" do
    mail = described_class.invite_email(invitation_id: invitation.id)
    url = "http://test.host/invite/#{invitation.token}"
    expect(mail.html_part.body.to_s).to include(url)
    expect(mail.text_part.body.to_s).to include(url)
  end

  it "falls back to inviter email if name is blank" do
    inviter.update!(name: nil)
    mail = described_class.invite_email(invitation_id: invitation.id)
    expect(mail.subject).to include("host@example.com")
  end

  it "raises a clear error when default_url_options[:host] is not configured" do
    original = ActionMailer::Base.default_url_options.dup
    ActionMailer::Base.default_url_options = original.except(:host)
    expect {
      described_class.invite_email(invitation_id: invitation.id).deliver_now
    }.to raise_error(RuntimeError, /default_url_options\[:host\] is not configured/)
  ensure
    ActionMailer::Base.default_url_options = original
  end
end
