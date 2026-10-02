# frozen_string_literal: true

# Nightly safety net for the live poller: registers anything in yesterday's daily index
# that full-text search did not surface. One or two SEC requests per run.
class ReconcileEdgarJob < ApplicationJob
  queue_as :default

  def perform(day = nil)
    day = day ? Date.iso8601(day) : Time.current.in_time_zone(Edgar::Submission::EDGAR_ZONE).to_date - 1

    Backfill.new.run_day(day)
  end
end
