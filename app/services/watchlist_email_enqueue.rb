# frozen_string_literal: true

class WatchlistEmailEnqueue
  def self.call(filing_id:, event_type:)
    # Retry pending rows after queue outages without extending membership evidence.
    ids = AlertDelivery.joins(:alert_rule).where(filing_id:, frequency: "instant", status: "pending",
      alert_rules: { scope: "watchlist", channel: "email", event_type:, active: true }).pluck(:id)
    ActiveRecord.after_all_transactions_commit do
      ids.each do |id|
        raise ActiveJob::EnqueueError, "Unable to enqueue watchlist email" unless SendAlertJob.perform_later(id)
      end
    end if ids.any?
  end
end
