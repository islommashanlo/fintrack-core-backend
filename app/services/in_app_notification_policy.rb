# frozen_string_literal: true

class InAppNotificationPolicy
  def self.pending(as_of:)
    pro_users = Billing::Entitlements.pro_user_ids.to_sql
    free_limit = PlanCatalog::PLANS.fetch("free").fetch(:alert_rules)
    InAppNotification.joins(:filing, alert_rule: [ :follow, :setting ])
      .joins("LEFT JOIN notification_preferences ON notification_preferences.user_id = follows.user_id")
      .where(published_at: nil, alert_rules: { channel: "in_app", event_type: "new_filing", active: true },
        follows: { removed_at: nil }, alert_rule_settings: { archived_at: nil },
        filings: { parse_status: "parsed", form_type: Filing::SEC_INGEST_TYPES })
      .where("filings.filed_at <= ? AND filings.filed_at >= alert_rule_settings.enabled_at", as_of)
      .where("in_app_notifications.rule_revision = alert_rule_settings.revision AND in_app_notifications.frequency = alert_rule_settings.frequency")
      .where("in_app_notifications.created_at >= alert_rule_settings.enabled_at")
      .where("in_app_notifications.frequency = 'instant' OR in_app_notifications.time_zone = notification_preferences.time_zone")
      .where("in_app_notifications.frequency = 'daily_digest' OR follows.user_id IN (#{pro_users})")
      .where("follows.user_id IN (#{pro_users}) OR (#{AlertRuleQuota::COUNT_FOR_OWNER_SQL}) <= ?", free_limit)
  end
end
