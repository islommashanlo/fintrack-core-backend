# frozen_string_literal: true

# The Sidekiq cron schedule from config/sidekiq_cron.yml, in the shape sidekiq-cron
# expects: a plain hash with string keys.
module CronSchedule
  def self.jobs
    Rails.application.config_for(:sidekiq_cron).to_h.deep_stringify_keys
  end
end
