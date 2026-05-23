ENV["RAILS_ENV"] ||= "test"

require_relative "spec_helper"
require_relative "dummy/config/environment"
require "rspec/rails"
Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

# Migrations are run manually via `cd spec/dummy && bin/rails db:migrate RAILS_ENV=test`.
# We don't auto-load schema here so the engine specs stay close to a real boot.

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
  config.include ActiveSupport::Testing::TimeHelpers
  config.include ActiveJob::TestHelper

  config.before(:each) do
    RailsMcp.reset_config!
    RailsMcp::Registry.reset!
    ActionMailer::Base.deliveries.clear
  end
end
