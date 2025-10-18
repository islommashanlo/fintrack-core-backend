# frozen_string_literal: true

require_relative 'boot'
require 'rails/all'

Bundler.require(*Rails.groups)

module BackendRuby
  class Application < Rails::Application
    config.load_defaults 7.1
    config.api_only = true

    # Required middlewares for RailsAdmin (even in API-only mode)
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Flash
    config.middleware.use Rack::MethodOverride
    config.middleware.use ActionDispatch::Session::CookieStore, { key: '_backend_ruby_session' }
  end
end
