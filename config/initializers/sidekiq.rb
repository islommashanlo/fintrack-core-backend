# frozen_string_literal: true

require "sidekiq"
require "sidekiq-cron"
require_relative "../../lib/notification_workers"

redis_config = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }

Sidekiq.configure_server do |config|
  config.redis = redis_config
  NotificationWorkers.configure(config)

  # Application scheduling remains enabled when SEC polling is off.
  config.on(:startup) do
    CronSchedule.load!
  end
end

Sidekiq.configure_client do |config|
  config.redis = redis_config
end
