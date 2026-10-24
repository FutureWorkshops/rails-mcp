require_relative "lib/rails_mcp/version"

Gem::Specification.new do |spec|
  spec.name        = "rails_mcp"
  spec.version     = RailsMcp::VERSION
  spec.authors     = [ "Future Workshops" ]
  spec.email       = [ "dev@futureworkshops.com" ]
  spec.summary     = "Rails engine providing MCP server scaffolding, an OAuth provider with dynamic client registration, and Groundwork SSO with identity mirroring."
  spec.license     = "MIT"

  spec.files       = Dir["{app,config,db,lib}/**/*", "README.md"].reject { |f| File.directory?(f) }
  spec.required_ruby_version = ">= 3.2"

  spec.add_dependency "rails", "~> 8.1"
  spec.add_dependency "doorkeeper", "~> 5.8"
  spec.add_dependency "rack-attack", "~> 6.7"
end
