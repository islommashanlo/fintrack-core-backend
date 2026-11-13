# frozen_string_literal: true

class AlertRuleQuota
  COUNT_FOR_OWNER_SQL = <<~SQL.squish.freeze
    SELECT COUNT(DISTINCT (quota_rules.scope, quota_rules.follow_id, quota_rules.event_type))
    FROM alert_rules quota_rules
    LEFT JOIN alert_rule_settings quota_settings ON quota_settings.alert_rule_id = quota_rules.id
    WHERE quota_rules.user_id = alert_rules.user_id AND quota_settings.archived_at IS NULL
  SQL

  def self.count(user)
    user.alert_rules.retained.distinct.count(Arel.sql("(alert_rules.scope, alert_rules.follow_id, alert_rules.event_type)"))
  end
end
