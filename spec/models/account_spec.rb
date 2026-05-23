require "rails_helper"

RSpec.describe RailsMcp::Account, type: :model do
  it "requires a name" do
    expect(described_class.new(name: nil)).not_to be_valid
  end

  it "tracks onboarded_at" do
    account = described_class.create!(name: "Acme")
    expect(account).not_to be_onboarded
    account.mark_onboarded!
    expect(account.reload).to be_onboarded
    expect(account.onboarded_at).to be_within(2.seconds).of(Time.current)
  end

  it "does not flip onboarded_at if already onboarded" do
    account = described_class.create!(name: "Acme")
    account.mark_onboarded!
    original = account.onboarded_at
    travel_to(1.minute.from_now) { account.mark_onboarded! }
    expect(account.reload.onboarded_at).to eq(original)
  end

  it "destroys users on destroy" do
    account = described_class.create!(name: "Acme")
    account.users.create!(email: "u@example.com", identity_id: "id-1")
    expect { account.destroy }.to change(RailsMcp::User, :count).by(-1)
  end
end
