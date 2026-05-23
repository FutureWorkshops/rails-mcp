module RailsMcp
  # Simple in-memory tool registry. Hosts populate it via:
  #
  #   RailsMcp::Registry.register(MyTool)
  #
  # The MCP controller reads from RailsMcp.config.tool_classes (which defaults
  # to Registry.all_tools), so apps may either register here or pass a custom
  # list/proc through configuration.
  module Registry
    @tools = []

    class << self
      def register(klass)
        @tools |= [ klass ]
        klass
      end

      def all_tools
        @tools.dup.freeze
      end

      def find(name)
        @tools.find { |t| t.tool_name == name }
      end

      def reset!
        @tools = []
      end
    end
  end
end
