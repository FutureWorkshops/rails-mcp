require "rails_helper"

# STI subclass defined inline so the spec doesn't depend on the host's classes.
class FakeConnection < RailsMcp::Connection
end

RSpec.describe RailsMcp::Connection, type: :model do
  let(:user) do
    account = RailsMcp::Account.create!(name: "Acme")
    account.users.create!(email: "u@example.com", identity_id: "id-1")
  end

  def build(**attrs)
    FakeConnection.create!({
      user: user,
      name: "Workspace",
      external_id: "ext-1",
      access_token: "tok",
      refresh_token: "rtok",
      token_expires_at: 1.hour.from_now
    }.merge(attrs))
  end

  it "encrypts access_token and refresh_token at rest" do
    conn = build
    ciphertext = ActiveRecord::Base.connection.select_value(
      "SELECT access_token FROM connections WHERE id = #{conn.id}"
    )
    expect(ciphertext).not_to eq("tok")
    expect(conn.reload.access_token).to eq("tok")
  end

  describe "#token_expired?" do
    it "is true when nil" do
      expect(build(token_expires_at: nil).token_expired?).to be true
    end

    it "is true when within 30 seconds" do
      expect(build(token_expires_at: 10.seconds.from_now).token_expired?).to be true
    end

    it "is false when comfortably in the future" do
      expect(build(token_expires_at: 1.hour.from_now).token_expired?).to be false
    end
  end

  describe "#needs_reconnect?" do
    it "is true once a permanent refresh failure has been recorded" do
      conn = build
      conn.mark_refresh_failed!("invalid_grant")
      expect(conn.reload).to be_needs_reconnect
    end
  end

  describe "#mark_refresh_succeeded!" do
    it "clears the refresh failure flags" do
      conn = build
      conn.mark_refresh_failed!("invalid_grant")
      conn.mark_refresh_succeeded!(access_token: "new", refresh_token: "newr", expires_in: 3600)
      conn.reload
      expect(conn.access_token).to eq("new")
      expect(conn).to be_token_active
      expect(conn.token_refresh_error).to be_nil
    end
  end

  it "enforces (user_id, external_id) uniqueness across STI types" do
    build(external_id: "ext-X")
    dup = FakeConnection.new(user: user, name: "Other", external_id: "ext-X")
    expect(dup).not_to be_valid
  end
end
