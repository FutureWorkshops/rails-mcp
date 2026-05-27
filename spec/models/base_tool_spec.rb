require "rails_helper"

RSpec.describe RailsMcp::BaseTool do
  def make_tool(name, schema = { type: "object", properties: {} })
    Class.new(described_class) do
      define_singleton_method(:tool_name)    { name }
      define_singleton_method(:description)  { "Test tool" }
      define_singleton_method(:input_schema) { schema }
      define_method(:call) { |**_| "ok" }
    end
  end

  it "infers readOnly annotations for list-/get-/search names" do
    %w[list-things get-thing search-things].each do |n|
      annotations = make_tool(n).annotations
      expect(annotations[:readOnlyHint]).to be true
      expect(annotations[:destructiveHint]).to be false
      expect(annotations[:idempotentHint]).to be true
    end
  end

  it "infers destructive annotations for delete- names" do
    annotations = make_tool("delete-thing").annotations
    expect(annotations[:destructiveHint]).to be true
    expect(annotations[:readOnlyHint]).to be false
  end

  it "infers idempotent annotations for update-/approve- names" do
    expect(make_tool("update-thing").annotations[:idempotentHint]).to be true
    expect(make_tool("approve-thing").annotations[:idempotentHint]).to be true
  end

  it "produces a tool_definition with name/description/inputSchema/annotations" do
    tool = make_tool("get-thing")
    defn = tool.tool_definition
    expect(defn).to include(name: "get-thing", description: "Test tool")
    expect(defn[:inputSchema]).to eq(type: "object", properties: {})
    expect(defn[:annotations][:title]).to eq("Get Thing")
  end

  describe ".human_title" do
    it "title-cases kebab-case tool names" do
      expect(make_tool("get-thing").human_title).to eq("Get Thing")
      expect(make_tool("list-card-table-columns").human_title).to eq("List Card Table Columns")
    end

    it "title-cases snake_case tool names (cli-mcp convention)" do
      expect(make_tool("cards_step_complete").human_title).to eq("Cards Step Complete")
      expect(make_tool("assignments_overdue").human_title).to eq("Assignments Overdue")
    end

    it "handles mixed and single-word names" do
      expect(make_tool("search").human_title).to eq("Search")
      expect(make_tool("api_get").human_title).to eq("Api Get")
    end
  end

  it "subclasses can override prefix constants" do
    subclass = Class.new(described_class) do
      define_singleton_method(:read_only_prefixes) { %w[show-] }
      define_singleton_method(:tool_name)    { "show-thing" }
      define_singleton_method(:description)  { "" }
      define_singleton_method(:input_schema) { { type: "object", properties: {} } }
    end
    expect(subclass.annotations[:readOnlyHint]).to be true
  end

  it "format_result serialises to pretty JSON" do
    tool_class = make_tool("get-thing")
    instance = tool_class.new(current_user: double)
    expect(JSON.parse(instance.format_result({ a: 1 }))).to eq("a" => 1)
  end
end
