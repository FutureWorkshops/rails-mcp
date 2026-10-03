require "rails_helper"

RSpec.describe RailsMcp::OauthState do
  it "accepts a matching state" do
    expect(described_class.valid?("abc123", "abc123")).to be(true)
  end

  it "rejects missing or mismatched state" do
    expect(described_class.valid?(nil, nil)).to be(false)
    expect(described_class.valid?(nil, "abc")).to be(false)
    expect(described_class.valid?("abc", nil)).to be(false)
    expect(described_class.valid?("", "")).to be(false)
    expect(described_class.valid?("abc", "abd")).to be(false)
  end
end
