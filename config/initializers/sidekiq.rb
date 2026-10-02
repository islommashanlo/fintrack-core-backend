# frozen_string_literal: true

require "sidekiq"
require "sidekiq-cron"

redis_config = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }

Sidekiq.configure_server do |config|
  config.redis = redis_config

  # Polling the SEC is opt-in. The schedule is loaded only when EDGAR_POLLING=on, and a
  # schedule left in Redis by an earlier run is removed when it is off.
  config.on(:startup) do
    if ENV["EDGAR_POLLING"] == "on"
      Sidekiq::Cron::Job.load_from_hash!(CronSchedule.jobs)
    else
      Sidekiq::Cron::Job.destroy_all!
    end
  end
end

Sidekiq.configure_client do |config|
  config.redis = redis_config
end
