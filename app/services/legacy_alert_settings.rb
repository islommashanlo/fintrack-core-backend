# frozen_string_literal: true

class LegacyAlertSettings
  def self.counts
    { rules_without_settings: AlertRule.where.missing(:setting).count,
      active_free_rules: AlertRule.active.left_outer_joins(:setting)
        .where("alert_rule_settings.id IS NULL OR alert_rule_settings.frequency = 'instant'").count }
  end

  def self.convert!
    # No paid entitlement records exist yet; every account is currently Free.
    ApplicationRecord.transaction do
      ApplicationRecord.connection.execute(<<~SQL)
        INSERT INTO alert_rule_settings (alert_rule_id, frequency, conditions, enabled_at, created_at, updated_at)
        SELECT id, 'instant', '{}'::jsonb, created_at, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM alert_rules
        WHERE NOT EXISTS (SELECT 1 FROM alert_rule_settings s WHERE s.alert_rule_id = alert_rules.id)
        ON CONFLICT (alert_rule_id) DO NOTHING
      SQL
      AlertRule.active.joins(:setting).where(alert_rule_settings: { frequency: "instant" }).update_all(active: false, updated_at: Time.current)
    end
  end
end
