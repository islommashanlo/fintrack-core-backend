# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

# Specs get their own Redis database and archive directory so they never touch
# development data, and a fixed contact address so SecClient can build its User-Agent.
ENV["REDIS_URL"] = ENV.fetch("TEST_REDIS_URL") do
  ENV.fetch("REDIS_URL", "redis://localhost:6379/0").sub(%r{/\d+\z}, "/15")
end
ENV["SEC_USER_AGENT_EMAIL"] = "specs@example.com"
ENV["FILING_ARCHIVE_ROOT"] = File.expand_path("../tmp/spec_archive", __dir__)

require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"
require "webmock/rspec"

Rails.root.glob("spec/support/**/*.rb").sort_by(&:to_s).each { |f| require f }

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

# Invariant 9: tests never hit the real SEC. Any unstubbed HTTP request raises.
WebMock.disable_net_connect!

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.include FactoryBot::Syntax::Methods
  config.include ActiveJob::TestHelper
  config.include ActiveSupport::Testing::TimeHelpers

  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.before(:each) do
    FilingsIntel.redis.call("FLUSHDB")
    FileUtils.rm_rf(ENV.fetch("FILING_ARCHIVE_ROOT"))
  end
end
