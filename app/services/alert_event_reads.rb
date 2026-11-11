# frozen_string_literal: true

class AlertEventReads
  def self.mark(user:, id:)
    user.with_lock do
      delivery = user.alert_deliveries.find(id)
      now = Time.current
      AlertEventState.insert_all([ { user_id: user.id, alert_delivery_id: delivery.id, read_at: now, created_at: now, updated_at: now } ],
        unique_by: [ :user_id, :alert_delivery_id ])
      AlertEventState.find_by!(user_id: user.id, alert_delivery_id: delivery.id)
    end
  end

  def self.mark_all(user:)
    user.with_lock do
      bound = user.alert_deliveries.maximum(:id) || 0
      now = Time.current
      sql = ApplicationRecord.sanitize_sql([ <<~SQL, user: user.id, bound:, now: ])
        WITH inserted AS (
          INSERT INTO alert_event_states (user_id, alert_delivery_id, read_at, created_at, updated_at)
          SELECT :user, d.id, :now, :now, :now FROM alert_deliveries d
          INNER JOIN alert_rules r ON r.id = d.alert_rule_id INNER JOIN follows f ON f.id = r.follow_id
          WHERE f.user_id = :user AND d.id <= :bound AND d.created_at <= :now
          ON CONFLICT (user_id, alert_delivery_id) DO NOTHING RETURNING 1
        ) SELECT COUNT(*) FROM inserted
      SQL
      { updated_count: ApplicationRecord.connection.select_value(sql).to_i, through_id: bound, as_of: now }
    end
  end
end
