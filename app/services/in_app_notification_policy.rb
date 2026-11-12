# frozen_string_literal: true

class InAppNotificationPolicy
  def self.pending(as_of:)
    pro_users = Billing::Entitlements.pro_user_ids.to_sql
    free_limit = PlanCatalog::PLANS.fetch("free").fetch(:alert_rules)
    scope = InAppNotification.left_joins(:filing).joins(alert_rule: [ :follow, :setting ])
      .joins("LEFT JOIN notification_preferences ON notification_preferences.user_id = follows.user_id")
      .where(published_at: nil, alert_rules: { channel: "in_app", event_type: AlertRule::IN_APP_EVENT_TYPES, active: true },
        follows: { removed_at: nil }, alert_rule_settings: { archived_at: nil })
      .where(<<~SQL.squish)
        (in_app_notifications.event_type <> 'news' AND filings.filed_at >= alert_rule_settings.enabled_at) OR EXISTS (
          SELECT 1 FROM news_alert_snapshots source WHERE source.id = in_app_notifications.news_alert_snapshot_id
            AND source.published_at >= alert_rule_settings.enabled_at AND source.published_at >= follows.followed_at
        )
      SQL
      .where("in_app_notifications.event_type = alert_rules.event_type")
      .where("in_app_notifications.rule_revision = alert_rule_settings.revision AND in_app_notifications.frequency = alert_rule_settings.frequency")
      .where("in_app_notifications.created_at >= alert_rule_settings.enabled_at")
      .where("in_app_notifications.frequency = 'instant' OR in_app_notifications.time_zone = notification_preferences.time_zone")
      .where("in_app_notifications.frequency = 'daily_digest' OR follows.user_id IN (#{pro_users})")
      .where("follows.user_id IN (#{pro_users}) OR (#{AlertRuleQuota::COUNT_FOR_OWNER_SQL}) <= ?", free_limit)
    InAppNotificationSource.apply(scope, as_of:)
  end
end
