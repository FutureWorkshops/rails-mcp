require "rails_helper"

RSpec.describe RailsMcp::ExceptionNotifierDefaults do
  describe ".redact?" do
    it "redacts strings starting with 'Bearer '" do
      expect(described_class.redact?("Bearer abc123")).to be true
    end

    it "redacts strings longer than 200 characters" do
      expect(described_class.redact?("x" * 201)).to be true
    end

    it "keeps short non-bearer strings" do
      expect(described_class.redact?("normal value")).to be false
    end

    it "ignores non-strings" do
      expect(described_class.redact?(42)).to be false
      expect(described_class.redact?(nil)).to be false
      expect(described_class.redact?({ foo: "bar" })).to be false
    end
  end

  describe ".slack_subscriber" do
    it "ignores handled errors" do
      subscriber = described_class.slack_subscriber
      expect(ExceptionNotifier).not_to receive(:notify_exception) if defined?(ExceptionNotifier)

      subscriber.report(StandardError.new("boom"), handled: true, severity: :warning, context: {})
    end
  end
end
