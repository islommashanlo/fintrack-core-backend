# frozen_string_literal: true

class AlertDeliveryPolicy
  def self.eligible?(delivery, user:, frequency:)
    scope(user:, frequency:).where(id: delivery.id).exists?
  end

  def self.scope(user:, frequency:)
    preference = user.notification_preference
    limit = PlanCatalog.limit_for(user, :alert_rules)
    return AlertDelivery.none unless preference&.email_enabled? && preference.email_enabled_at && preference.time_zone.present?
    return AlertDelivery.none if limit && user.alert_rules.retained.count > limit
    return AlertDelivery.none if frequency == "instant" && !PlanCatalog.limit_for(user, :instant_alerts)

    AlertDelivery.joins(alert_rule: [ :setting, :follow ])
      .where(frequency:, alert_rules: { active: true }, follows: { user_id: user.id, removed_at: nil },
        alert_rule_settings: { archived_at: nil, frequency: })
      .where("alert_deliveries.created_at >= alert_rule_settings.enabled_at AND alert_deliveries.created_at >= ?", preference.email_enabled_at)
  end
end
