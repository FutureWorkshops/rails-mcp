require "rails_helper"

RSpec.describe RailsMcp::Account, type: :model do
  it "requires a name" do
    expect(described_class.new(name: nil)).not_to be_valid
  end


  it "destroys users on destroy" do
    account = described_class.create!(name: "Acme")
    account.users.create!(email: "u@example.com", identity_id: "id-1")
    expect { account.destroy }.to change(RailsMcp::User, :count).by(-1)
  end
end
