# frozen_string_literal: true

class AlertInboxSummary
  def self.call(user:, as_of: Time.current)
    sql = ApplicationRecord.sanitize_sql([ <<~SQL, user: user.id, as_of: ])
      SELECT COUNT(*) AS total_count,
        COUNT(*) FILTER (WHERE state.read_at IS NULL) AS unread_count,
        COUNT(*) FILTER (WHERE state.read_at IS NOT NULL) AS read_count
      FROM alert_deliveries d
      INNER JOIN alert_rules r ON r.id = d.alert_rule_id
      LEFT JOIN alert_event_states state ON state.alert_delivery_id = d.id AND state.user_id = :user
      WHERE r.user_id = :user AND d.created_at <= :as_of
    SQL
    counts = ApplicationRecord.connection.select_one(sql).transform_values(&:to_i)
    counts.symbolize_keys.merge(as_of:)
  end
end
