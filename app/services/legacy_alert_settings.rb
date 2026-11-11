# frozen_string_literal: true

class LegacyAlertSettings
  def self.counts
    { rules_without_settings: AlertRule.where.missing(:setting).count,
      active_free_rules: free_instant_rules.count }
  end

  def self.convert!
    ApplicationRecord.transaction do
      ApplicationRecord.connection.execute(<<~SQL)
        INSERT INTO alert_rule_settings (alert_rule_id, frequency, conditions, enabled_at, created_at, updated_at)
        SELECT id, 'instant', '{}'::jsonb, created_at, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM alert_rules
        WHERE NOT EXISTS (SELECT 1 FROM alert_rule_settings s WHERE s.alert_rule_id = alert_rules.id)
        ON CONFLICT (alert_rule_id) DO NOTHING
      SQL
      free_instant_rules.update_all(active: false, updated_at: Time.current)
    end
  end

  def self.free_instant_rules
    AlertRule.active.left_outer_joins(:setting).joins(:follow)
      .where("alert_rule_settings.id IS NULL OR alert_rule_settings.frequency = 'instant'")
      .where.not(follows: { user_id: Billing::Entitlements.pro_user_ids })
  end
  private_class_method :free_instant_rules
end
