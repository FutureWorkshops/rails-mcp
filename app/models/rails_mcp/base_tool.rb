module RailsMcp
  # Abstract base for MCP tools. Subclasses define `tool_name`, `description`,
  # `input_schema`, and an instance `call` method. The engine derives the
  # MCP-shaped tool definition and annotation hints from the class name's prefix.
  #
  # Host apps usually create their own subclass to attach domain helpers
  # (HTTP client, API error class, account/tenant lookup, etc.) and have their
  # concrete tools inherit from that.
  class BaseTool
    READ_ONLY_PREFIXES   = %w[list- get- search].freeze
    DESTRUCTIVE_PREFIXES = %w[delete- trash- archive-].freeze
    IDEMPOTENT_PREFIXES  = %w[update- complete- uncomplete- approve- revert- archive- restore-].freeze

    attr_reader :current_user

    def initialize(current_user:)
      @current_user = current_user
    end

    def self.tool_definition
      {
        name: tool_name,
        description: description,
        inputSchema: input_schema,
        annotations: annotations
      }
    end

    def self.annotations
      name = tool_name.to_s
      read_only   = read_only_prefixes.any?   { |p| name.start_with?(p) }
      destructive = destructive_prefixes.any? { |p| name.start_with?(p) }
      idempotent  = idempotent_prefixes.any?  { |p| name.start_with?(p) }

      {
        title: human_title,
        readOnlyHint: read_only,
        destructiveHint: !read_only && destructive,
        idempotentHint: read_only || idempotent,
        openWorldHint: true
      }
    end

    # Turn `cards_step_complete` or `cards-step-complete` into
    # `Cards Step Complete`. Handles both snake_case (cli-mcp convention) and
    # kebab-case (legacy MCP naming) consistently. MCP clients render this as
    # the tool's display label in their UI.
    def self.human_title
      tool_name.to_s.tr("-_", "  ").split.map(&:capitalize).join(" ")
    end

    # Overridable in subclasses (without redefining annotations).
    def self.read_only_prefixes   = READ_ONLY_PREFIXES
    def self.destructive_prefixes = DESTRUCTIVE_PREFIXES
    def self.idempotent_prefixes  = IDEMPOTENT_PREFIXES

    # Subclasses must override these:
    def self.tool_name    = raise NotImplementedError
    def self.description  = raise NotImplementedError
    def self.input_schema = { type: "object", properties: {} }

    def call(**)
      raise NotImplementedError
    end

    # Default result serialiser. Subclasses can override.
    def format_result(data)
      JSON.pretty_generate(data)
    rescue StandardError => e
      "Serialisation failed (#{e.class}: #{e.message}). Raw: #{data.inspect[0, 2000]}"
    end
  end
end
