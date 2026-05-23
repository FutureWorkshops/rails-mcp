module RailsMcp
  class ApplicationMailer < ActionMailer::Base
    default from: -> { RailsMcp.config.mailer_from }
    layout "rails_mcp/mailer"
  end
end
