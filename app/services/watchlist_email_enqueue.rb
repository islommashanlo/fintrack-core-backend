# frozen_string_literal: true

class WatchlistEmailEnqueue
  def self.call(event_type:, filing_id: nil, news_item_id: nil)
    raise ArgumentError, "Provide exactly one source" if filing_id.nil? == news_item_id.nil?
    source = news_item_id ? { news_item_id: } : { filing_id: }
    # Retry pending rows after queue outages without extending membership evidence.
    ids = AlertDelivery.joins(:alert_rule).where(source).where(frequency: "instant", status: "pending",
      alert_rules: { scope: "watchlist", channel: "email", event_type:, active: true }).pluck(:id)
    ActiveRecord.after_all_transactions_commit do
      ids.each do |id|
        raise ActiveJob::EnqueueError, "Unable to enqueue watchlist email" unless SendAlertJob.perform_later(id)
      end
    end if ids.any?
  end
end
