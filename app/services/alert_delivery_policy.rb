# frozen_string_literal: true

class AlertDeliveryPolicy
  def self.eligible?(delivery, user:, frequency:)
    scope(user:, frequency:).where(id: delivery.id).exists?
  end

  def self.scope(user:, frequency:)
    preference = user.notification_preference
    limit = PlanCatalog.limit_for(user, :alert_rules)
    return AlertDelivery.none unless preference&.email_enabled? && preference.email_enabled_at && preference.time_zone.present?
    return AlertDelivery.none if limit && AlertRuleQuota.count(user) > limit
    return AlertDelivery.none if frequency == "instant" && !PlanCatalog.limit_for(user, :instant_alerts)

    scope = AlertDelivery.joins(alert_rule: :setting).left_joins(alert_rule: :follow)
      .where(frequency:, alert_rules: { active: true, user_id: user.id },
        alert_rule_settings: { archived_at: nil, frequency: })
      .where("(alert_rules.scope = 'follow' AND follows.removed_at IS NULL) OR (alert_rules.scope = 'watchlist' AND #{WatchlistFilingMembership.pending_sql(channel: 'email')})")
      .where("alert_deliveries.created_at >= alert_rule_settings.enabled_at AND alert_deliveries.created_at >= ?", preference.email_enabled_at)
      .where("alert_deliveries.rule_revision = alert_rule_settings.revision")
    AlertSourceValidity.apply(scope, as_of: Time.current)
  end
end
