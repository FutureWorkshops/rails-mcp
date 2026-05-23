module RailsMcp
  # Configuration is intentionally a plain object with lazy defaults: hosts can set
  # any subset of values; unset ones derive from `server_name` at read time.
  class Configuration
    attr_writer :server_name, :server_version, :display_name, :resource_name,
                :scopes, :scope_descriptions, :tools, :tool_error_handler,
                :mailer_from, :suggested_account_name, :sign_in_path

    def server_name
      @server_name || Rails.application.class.module_parent_name.underscore
    end

    def server_version
      @server_version || "0.1.0"
    end

    def display_name
      @display_name || server_name.titleize
    end

    def resource_name
      @resource_name || "#{display_name} Server"
    end

    def scopes
      @scopes || %w[read write]
    end

    def scope_descriptions
      @scope_descriptions || {}
    end

    def tools
      @tools || -> { RailsMcp::Registry.all_tools }
    end

    def tool_classes
      list = tools.respond_to?(:call) ? tools.call : tools
      Array(list)
    end

    def tool_error_handler
      @tool_error_handler
    end

    def mailer_from
      @mailer_from || "#{display_name} <no-reply@example.com>"
    end

    def suggested_account_name
      @suggested_account_name || ->(_user) { nil }
    end

    def sign_in_path
      @sign_in_path || ->(_request) { "/sign_in" }
    end
  end
end
