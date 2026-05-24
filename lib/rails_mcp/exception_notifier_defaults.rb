module RailsMcp
  # Recommended ExceptionNotification config for an MCP server. The engine
  # doesn't depend on the `exception_notification` or `slack-notifier` gems
  # directly — hosts add them to their own Gemfile and call:
  #
  #   # config/initializers/exception_notification.rb
  #   if Rails.env.production? && ENV["SLACK_WEBHOOK_URL"].present?
  #     RailsMcp::ExceptionNotifierDefaults.apply!(
  #       webhook_url: ENV["SLACK_WEBHOOK_URL"],
  #       channel:     ENV.fetch("SLACK_ERROR_CHANNEL", "#errors"),
  #       username:    "basecamp-mcp"
  #     )
  #   end
  #
  # The defaults are deliberately conservative: only `backtrace` + `data`
  # sections are included in the Slack payload (no request body, no Rack env),
  # and we filter individual data values that look like bearer tokens or long
  # opaque blobs.
  module ExceptionNotifierDefaults
    DEFAULT_USERNAME = "rails-mcp"

    BEARER_PREFIX = "Bearer "
    MAX_DATA_VALUE_LENGTH = 200

    DEFAULT_IGNORED_EXCEPTIONS = %w[
      ActionController::RoutingError
      ActionController::BadRequest
    ].freeze

    def self.apply!(webhook_url:, channel: "#errors", username: DEFAULT_USERNAME, additional_parameters: {})
      require "exception_notification"
      require "exception_notification/rails"

      ExceptionNotification.configure do |config|
        config.ignored_exceptions += DEFAULT_IGNORED_EXCEPTIONS

        config.add_notifier :slack,
          webhook_url:           webhook_url,
          channel:               channel,
          username:              username,
          additional_parameters: { mrkdwn: true }.merge(additional_parameters),
          ignore_data_if:        ->(_key, value) { redact?(value) },
          sections:              %w[backtrace data]
      end

      Rails.application.config.middleware.use ExceptionNotification::Rack

      # Errors reported via Rails.error.handle / record (Active Job, Solid
      # Queue, anything that uses the structured error reporter) also reach
      # Slack via this subscriber.
      Rails.error.subscribe(slack_subscriber)
      true
    end

    def self.redact?(value)
      return false unless value.is_a?(String)

      value.start_with?(BEARER_PREFIX) || value.length > MAX_DATA_VALUE_LENGTH
    end

    def self.slack_subscriber
      Class.new do
        def report(exception, handled:, severity:, context:, source: nil)
          return if handled

          ExceptionNotifier.notify_exception(
            exception,
            data: { severity: severity, source: source, context: context }
          )
        end
      end.new
    end
  end
end
