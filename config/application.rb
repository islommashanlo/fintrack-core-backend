# frozen_string_literal: true

require_relative "boot"

require "rails"
require_relative "../lib/middleware/api_cors"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module FilingsIntel
  # Shown wherever data is presented to a reader (brief section 1).
  DISCLAIMER = "Data from public SEC filings. Not investment advice."

  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0
    config.action_cable.mount_path = nil
    config.action_cable.allowed_request_origins = [ Middleware::ApiCors.origin ].compact

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])
    config.middleware.insert_before ActionDispatch::Cookies, Middleware::ApiCors

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # Jobs run on Sidekiq; the test environment overrides this with the test adapter.
    config.active_job.queue_adapter = :sidekiq

    config.generators do |g|
      g.test_framework :rspec, fixtures: false, view_specs: false, helper_specs: false, routing_specs: false
      g.factory_bot dir: "spec/factories"
    end
  end
end
