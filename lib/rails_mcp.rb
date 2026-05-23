require "rails_mcp/version"
require "rails_mcp/configuration"
require "rails_mcp/engine"
require "rails_mcp/rack_attack_defaults"

module RailsMcp
  class << self
    def configure
      yield config
    end

    def config
      @config ||= Configuration.new
    end

    def reset_config!
      @config = Configuration.new
    end
  end
end
