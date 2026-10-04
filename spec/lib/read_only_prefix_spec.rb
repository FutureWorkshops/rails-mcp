require "rails_helper"

RSpec.describe RailsMcp::BaseTool do
  def tool_named(name)
    Class.new(described_class) { define_singleton_method(:tool_name) { name } }
  end

  it "treats search, search-x and search_x as read-only" do
    %w[search search-messages search_cards].each do |name|
      expect(tool_named(name).annotations[:readOnlyHint]).to be(true), name
    end
  end

  it "doesn't treat names that merely start with 'search' as read-only" do
    expect(tool_named("searchandreplace").annotations[:readOnlyHint]).to be(false)
  end
end
