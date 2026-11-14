# frozen_string_literal: true

source "https://rubygems.org"

gem "rails", "~> 8.1.4", ">= 8.1.4.1"
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# json 3 dropped the quirks_mode option that Active Support 8.0's JSON encoder passes,
# which breaks every to_json call. Remove this pin once Rails no longer needs it.
gem "json", "< 3"

# Background jobs and the cron schedule for the EDGAR poller.
# Sidekiq 8, not 7: the 7.3 scheduler thread crashes against connection_pool 3,
# which silently stops scheduled jobs (retries) and cron.
gem "sidekiq", "~> 8.0"
gem "sidekiq-cron", "~> 2.0"

# Redis access for the SEC rate limiter (already a Sidekiq dependency)
gem "redis-client"

# SEC HTTP (only through SecClient) and filing XML
gem "faraday", "~> 2.0"
gem "nokogiri", "~> 1.18"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  gem "rspec-rails", ">= 7.1"
  gem "factory_bot_rails"
end

group :test do
  # Blocks all real HTTP in specs; tests must never reach the SEC
  gem "webmock"
end

group :development do
  # CI security checks; not loaded by the application or installed in production.
  gem "brakeman", "~> 8.1", require: false
  gem "bundler-audit", "~> 0.9.3", require: false

  gem "web-console"
end

gem "bcrypt", "~> 3.1"

# Google ID-token verification; linking is disabled unless explicitly configured.
gem "googleauth", "~> 1.17", require: false
