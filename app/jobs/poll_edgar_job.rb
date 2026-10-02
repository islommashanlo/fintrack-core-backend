# frozen_string_literal: true

# Runs every minute from the cron schedule (config/sidekiq_cron.yml).
# A failed poll is not retried: the next minute's run covers the same ground, and the
# stale "last successful poll" time is what makes the failure visible.
class PollEdgarJob < ApplicationJob
  queue_as :sec_live_form4
  sidekiq_options retry: 0 if respond_to?(:sidekiq_options)

  def perform
    EdgarPoller.new.poll
  rescue SecClient::Error, Edgar::FullTextSearch::UnexpectedResponse => e
    Rails.logger.warn("EDGAR poll failed: #{e.class}: #{e.message}")
  end
end
