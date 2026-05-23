require "rails_helper"

RSpec.describe RailsMcp::User, type: :model do
  let(:account) { RailsMcp::Account.create!(name: "Acme") }

  it "requires email + identity_id" do
    expect(described_class.new(account: account)).not_to be_valid
  end

  it "normalizes email" do
    user = account.users.create!(email: "  Foo@Example.com ", identity_id: "id-1")
    expect(user.email).to eq("foo@example.com")
  end

  it "rejects duplicate email" do
    account.users.create!(email: "a@example.com", identity_id: "id-1")
    dup = account.users.build(email: "A@example.com", identity_id: "id-2")
    expect(dup).not_to be_valid
  end

  it "rejects duplicate identity_id" do
    account.users.create!(email: "a@example.com", identity_id: "shared")
    other = RailsMcp::Account.create!(name: "Other").users.build(email: "b@example.com", identity_id: "shared")
    expect(other).not_to be_valid
  end
end
