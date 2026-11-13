# frozen_string_literal: true

class NewsAlertEvaluator
  def self.call(item, as_of: Time.current)
    InAppNotificationMatcher.news(item, as_of:)
    WatchlistNewsMatcher.call(item, channel: "email", as_of:)
    inserted_ids, instant_ids = NewsAlertSnapshot.transaction do
      rows = NewsAlertMatcher.call(item, as_of:).map do |row|
        { alert_rule_id: row.fetch("rule_id"), news_item_id: row.fetch("news_item_id"),
          news_alert_snapshot_id: row.fetch("news_alert_snapshot_id"), event_type: "news",
          status: "pending", frequency: row.fetch("frequency"), rule_revision: row.fetch("rule_revision"),
          created_at: Time.current, updated_at: Time.current }
      end
      return [] if rows.empty?

      inserted = AlertDelivery.insert_all(rows, unique_by: :index_alert_deliveries_on_rule_and_news_item, returning: %w[id frequency])
      pending = AlertDelivery.where(news_item_id: item.id, alert_rule_id: rows.map { |row| row.fetch(:alert_rule_id) },
        frequency: "instant", status: %w[pending failed]).pluck(:id)
      [ inserted.rows.map(&:first), pending ]
    end
    # Existing unsent rows are retried too: a queue failure after commit must not
    # strand a delivery. SendAlertJob serializes duplicate attempts under a lock.
    ActiveRecord.after_all_transactions_commit { instant_ids.each { |id| SendAlertJob.perform_later(id) } }
    inserted_ids
  end
end
