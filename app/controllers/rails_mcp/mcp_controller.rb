module RailsMcp
  class McpController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false
    # Require either read or write at the OAuth provider level; the per-tool
    # check inside handle_tool_call decides which of the two is actually needed.
    before_action -> { doorkeeper_authorize! :read, :write }
    before_action :require_existing_user
    before_action :require_onboarded_account

    PROTOCOL_VERSION = "2024-11-05"

    def handle
      body = JSON.parse(request.raw_post)

      if body.is_a?(Array)
        results = body.filter_map { |msg| dispatch_message(msg) }
        render json: results
      else
        result = dispatch_message(body)
        result ? render(json: result) : head(:no_content)
      end
    rescue JSON::ParserError
      render json: json_error(nil, -32700, "Parse error"), status: :bad_request
    end

    # RFC 9728: WWW-Authenticate points to /.well-known/oauth-protected-resource.
    def doorkeeper_unauthorized_render_options(error: nil)
      metadata_url = RailsMcp::Engine.routes.url_helpers
                       .oauth_protected_resource_metadata_url(
                         host: request.host, port: request.port, protocol: request.protocol
                       )
      response.headers["WWW-Authenticate"] = %(Bearer resource_metadata="#{metadata_url}")
      { json: json_error(nil, -32001, error&.description || "Unauthorized") }
    end

    private

    def require_existing_user
      return if mcp_user

      render json: json_error(nil, -32001, "Authorizing user no longer exists"),
             status: :unauthorized
    end

    def require_onboarded_account
      return if mcp_user.account.onboarded?

      render json: json_error(nil, -32001,
        "Account onboarding is incomplete. Sign in at the web dashboard to finish setup before using MCP tools."),
        status: :forbidden
    end

    def mcp_user
      @mcp_user ||= RailsMcp::User.find_by(id: doorkeeper_token.resource_owner_id)
    end

    def dispatch_message(msg)
      id     = msg["id"]
      method = msg["method"]
      params = msg["params"] || {}

      return nil if id.nil? && method&.start_with?("notifications/")

      case method
      when "initialize"                then handle_initialize(id)
      when "tools/list"                then handle_tools_list(id)
      when "tools/call"                then handle_tool_call(id, params)
      when "notifications/initialized" then nil
      else json_error(id, -32601, "Method not found: #{method}")
      end
    end

    def handle_initialize(id)
      json_success(id, {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: {
          name: RailsMcp.config.server_name,
          version: RailsMcp.config.server_version
        }
      })
    end

    def handle_tools_list(id)
      json_success(id, { tools: RailsMcp.config.tool_classes.map(&:tool_definition) })
    end

    def handle_tool_call(id, params)
      tool_class = RailsMcp.config.tool_classes.find { |t| t.tool_name == params["name"] }
      return json_error(id, -32601, "Unknown tool: #{params['name']}") unless tool_class

      unless authorized_for_tool?(tool_class)
        return json_success(id, {
          content: [ { type: "text", text: insufficient_scope_message(tool_class) } ],
          isError: true
        })
      end

      arguments = (params["arguments"] || {}).symbolize_keys
      if (unknown = unknown_arguments(tool_class, arguments)).any?
        message = unknown_argument_message(tool_class, unknown)
        return json_success(id, { content: [ { type: "text", text: message } ], isError: true })
      end

      result = tool_class.new(current_user: mcp_user).call(**arguments)
      json_success(id, { content: [ { type: "text", text: result.to_s } ], isError: false })
    rescue StandardError => e
      text = host_error_text(e, tool_class) || "Error: #{e.message}"
      Rails.logger.error("MCP tool call failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}") unless host_error_text(e, tool_class)
      json_success(id, { content: [ { type: "text", text: text } ], isError: true })
    end

    # Read-only tools require the `read` scope; everything else (create/update/
    # delete/post/etc.) requires `write`. We use the tool's annotation rather
    # than asking each tool to declare its scope explicitly, so the contract
    # stays in lockstep with the `readOnlyHint` advertised to the LLM.
    def authorized_for_tool?(tool_class)
      required = required_scope_for(tool_class)
      Array(doorkeeper_token.scopes).map(&:to_s).include?(required.to_s)
    end

    def required_scope_for(tool_class)
      tool_class.annotations[:readOnlyHint] ? :read : :write
    end

    def insufficient_scope_message(tool_class)
      "Insufficient OAuth scope for tool #{tool_class.tool_name}: requires '#{required_scope_for(tool_class)}'."
    end

    def host_error_text(error, tool_class)
      handler = RailsMcp.config.tool_error_handler
      return nil unless handler

      handler.call(error, tool_class: tool_class, current_user: mcp_user)
    end

    def unknown_arguments(tool_class, arguments)
      allowed = (tool_class.input_schema[:properties] || {}).keys.map(&:to_sym)
      arguments.keys - allowed
    end

    def unknown_argument_message(tool_class, unknown)
      allowed = (tool_class.input_schema[:properties] || {}).keys
      "Unknown argument(s) for #{tool_class.tool_name}: #{unknown.join(', ')}. " \
        "Accepted arguments: #{allowed.join(', ')}."
    end

    def json_success(id, result) = { jsonrpc: "2.0", id: id, result: result }
    def json_error(id, code, message) = { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
  end
end
