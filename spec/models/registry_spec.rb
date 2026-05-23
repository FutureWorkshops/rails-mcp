require "rails_helper"

RSpec.describe RailsMcp::Registry do
  let(:tool_class) do
    Class.new(RailsMcp::BaseTool) do
      define_singleton_method(:tool_name)    { "list-things" }
      define_singleton_method(:description)  { "" }
      define_singleton_method(:input_schema) { { type: "object", properties: {} } }
    end
  end

  it "registers and looks up tools" do
    described_class.register(tool_class)
    expect(described_class.all_tools).to include(tool_class)
    expect(described_class.find("list-things")).to eq(tool_class)
  end

  it "dedupes on repeated registration" do
    2.times { described_class.register(tool_class) }
    expect(described_class.all_tools.count(tool_class)).to eq(1)
  end

  it "reset! clears state" do
    described_class.register(tool_class)
    described_class.reset!
    expect(described_class.all_tools).to be_empty
  end
end
