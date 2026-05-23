require "rails_helper"

RSpec.describe RailsMcp::Invitation, type: :model do
  let(:account) { RailsMcp::Account.create!(name: "Acme") }
  let(:inviter) { account.users.create!(email: "host@example.com", identity_id: "host") }

  def build(**attrs)
    account.invitations.create!({ email: "guest@example.com", invited_by: inviter }.merge(attrs))
  end

  it "auto-generates a token and 14-day expiry" do
    inv = build
    expect(inv.token).to be_present
    expect(inv.expires_at).to be_within(2.seconds).of(14.days.from_now)
  end

  it "normalizes email and validates format" do
    expect { build(email: "  Foo@Example.com ") }.not_to raise_error
    expect(account.invitations.last.email).to eq("foo@example.com")
    expect(RailsMcp::Invitation.new(account: account, email: "not-an-email")).not_to be_valid
  end

  it "exposes state predicates and #claimable_by?" do
    inv = build
    expect(inv).to be_pending
    expect(inv.claimable_by?("guest@example.com")).to be true
    expect(inv.claimable_by?("GUEST@example.com")).to be true
    expect(inv.claimable_by?("other@example.com")).to be false

    inv.accept!
    expect(inv).to be_accepted
    expect(inv.claimable_by?("guest@example.com")).to be false
  end

  it "#revoke! and #accept! are idempotent" do
    inv = build
    inv.revoke!
    revoked_at = inv.revoked_at
    inv.revoke!
    expect(inv.reload.revoked_at).to eq(revoked_at)
  end

  it ".pending excludes accepted, revoked, expired" do
    accepted = build(email: "a@example.com")
    accepted.accept!
    revoked  = build(email: "r@example.com")
    revoked.revoke!
    expired  = build(email: "x@example.com", expires_at: 1.day.ago)
    pending  = build(email: "p@example.com")

    expect(RailsMcp::Invitation.pending).to contain_exactly(pending)
  end

  describe ".consume_from_session!" do
    let(:invitation) { build }

    it "returns nil when no token in session" do
      result = described_class.consume_from_session!({}, candidate_email: "x@example.com")
      expect(result).to be_nil
    end

    it "yields :unknown when the token isn't found" do
      called = nil
      result = described_class.consume_from_session!(
        { RailsMcp::Invitation::SESSION_KEY => "bogus" },
        candidate_email: "x@example.com"
      ) { |e| called = e }
      expect(called).to eq(:unknown)
      expect(result).to be_nil
    end

    it "yields :not_pending when accepted" do
      invitation.accept!
      called = nil
      described_class.consume_from_session!(
        { RailsMcp::Invitation::SESSION_KEY => invitation.token },
        candidate_email: "guest@example.com"
      ) { |e| called = e }
      expect(called).to eq(:not_pending)
    end

    it "yields :email_mismatch when emails differ" do
      called = nil
      described_class.consume_from_session!(
        { RailsMcp::Invitation::SESSION_KEY => invitation.token },
        candidate_email: "different@example.com"
      ) { |e| called = e }
      expect(called).to eq(:email_mismatch)
    end

    it "returns the invitation when valid" do
      session = { RailsMcp::Invitation::SESSION_KEY => invitation.token }
      result = described_class.consume_from_session!(session, candidate_email: "guest@example.com")
      expect(result).to eq(invitation)
      expect(session).not_to have_key(RailsMcp::Invitation::SESSION_KEY)
    end
  end
end
