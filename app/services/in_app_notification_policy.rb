# frozen_string_literal: true

class InAppNotificationPolicy
  def self.pending(as_of:)
    pro_users = Billing::Entitlements.pro_user_ids.to_sql
    free_limit = PlanCatalog::PLANS.fetch("free").fetch(:alert_rules)
    scope = InAppNotification.left_joins(:filing).joins(alert_rule: :setting).left_joins(alert_rule: :follow)
      .joins("LEFT JOIN notification_preferences ON notification_preferences.user_id = alert_rules.user_id")
      .where(published_at: nil, alert_rules: { channel: "in_app", event_type: AlertRule::IN_APP_EVENT_TYPES, active: true },
        alert_rule_settings: { archived_at: nil })
      .where("(alert_rules.scope = 'follow' AND follows.removed_at IS NULL) OR (alert_rules.scope = 'watchlist' AND (#{WatchlistFilingMembership.pending_sql} OR #{WatchlistNewsMembership.pending_sql(channel: 'in_app', as_of: as_of)}))")
      .where(<<~SQL.squish)
        (in_app_notifications.event_type <> 'news' AND filings.filed_at >= alert_rule_settings.enabled_at) OR EXISTS (
          SELECT 1 FROM news_alert_snapshots source WHERE source.id = in_app_notifications.news_alert_snapshot_id
            AND source.published_at >= alert_rule_settings.enabled_at AND (alert_rules.scope = 'watchlist' OR source.published_at >= follows.followed_at)
        )
      SQL
      .where("in_app_notifications.event_type = alert_rules.event_type")
      .where("in_app_notifications.rule_revision = alert_rule_settings.revision AND in_app_notifications.frequency = alert_rule_settings.frequency")
      .where("in_app_notifications.created_at >= alert_rule_settings.enabled_at")
      .where("in_app_notifications.frequency = 'instant' OR in_app_notifications.time_zone = notification_preferences.time_zone")
      .where("in_app_notifications.frequency = 'daily_digest' OR alert_rules.user_id IN (#{pro_users})")
      .where("alert_rules.user_id IN (#{pro_users}) OR (#{AlertRuleQuota::COUNT_FOR_OWNER_SQL}) <= ?", free_limit)
    InAppNotificationSource.apply(scope, as_of:)
  end
end
