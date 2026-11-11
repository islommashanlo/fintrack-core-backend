# frozen_string_literal: true

# The Sidekiq cron schedule from config/sidekiq_cron.yml, in the shape sidekiq-cron
# expects: a plain hash with string keys.
module CronSchedule
  def self.jobs(polling: ENV["EDGAR_POLLING"] == "on")
    jobs = Rails.application.config_for(:sidekiq_cron).to_h.deep_stringify_keys
    polling ? jobs : jobs.slice("alert_digests")
  end

  def self.load!(polling: ENV["EDGAR_POLLING"] == "on")
    selected = jobs(polling:)
    (jobs(polling: true).keys - selected.keys).each { |name| Sidekiq::Cron::Job.destroy(name) }
    Sidekiq::Cron::Job.load_from_hash!(selected)
  end
end
