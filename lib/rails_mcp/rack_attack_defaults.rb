require "rack/attack"

module RailsMcp
  # Recommended Rack::Attack throttles for an MCP server. The host opts in by
  # calling `RailsMcp::RackAttackDefaults.apply!` from a Rails initializer; we
  # don't register middleware automatically because some hosts want a different
  # cache backend (Redis vs memory) or stricter limits.
  #
  #   # config/initializers/rack_attack.rb
  #   Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
  #   RailsMcp::RackAttackDefaults.apply!
  #
  # All limits are tunable via kwargs on `apply!`. Pass `register_per_ip: 0` or
  # similar to disable an individual throttle.
  module RackAttackDefaults
    DEFAULTS = {
      register_per_ip:        { limit: 5,   period: 15 * 60 },   # /oauth/register
      mcp_per_token:          { limit: 120, period: 60 },        # POST /mcp by access token
      mcp_per_ip:             { limit: 300, period: 60 },        # POST /mcp by IP (fallback)
      invitations_per_user:   { limit: 20,  period: 60 * 60 },   # POST /team/invitations
      basecamp_connect_per_ip: { limit: 30, period: 60 }         # GET /basecamp/connect, host-side
    }.freeze

    def self.apply!(**overrides)
      limits = DEFAULTS.merge(overrides)

      throttle("rails_mcp/oauth/register by ip", **limits[:register_per_ip]) do |req|
        req.ip if req.post? && req.path.end_with?("/oauth/register")
      end

      throttle("rails_mcp/mcp by token", **limits[:mcp_per_token]) do |req|
        if req.post? && req.path == "/mcp"
          header = req.get_header("HTTP_AUTHORIZATION").to_s
          header.start_with?("Bearer ") ? header.split(" ", 2).last : nil
        end
      end

      throttle("rails_mcp/mcp by ip", **limits[:mcp_per_ip]) do |req|
        req.ip if req.post? && req.path == "/mcp"
      end

      throttle("rails_mcp/team/invitations by user", **limits[:invitations_per_user]) do |req|
        if req.post? && req.path == "/team/invitations"
          req.env["rack.session"]&.[]("user_id") || req.ip
        end
      end

      true
    end

    def self.throttle(name, limit:, period:)
      return if limit.to_i <= 0

      Rack::Attack.throttle(name, limit: limit, period: period) do |req|
        yield(req)
      end
    end
  end
end
