# frozen_string_literal: true

class AlertRuleControl
  Result = Data.define(:rule, :created)
  class InvalidConfiguration < StandardError; end

  def self.create(user:, follow_id:, attributes:)
    user.with_lock do
      follow = user.follows.current.find(follow_id)
      rule = follow.alert_rule
      existing = rule && rule.setting&.archived_at.nil?
      assert_slot!(user) unless existing
      rule ||= follow.create_alert_rule!(active: false)
      ensure_setting!(rule)
      rule.setting.update!(frequency: "daily_digest") if !existing && !attributes.key?(:frequency)
      rule.setting.update!(archived_at: nil)
      apply(user:, rule:, attributes:)
      Result.new(rule:, created: !existing)
    end
  end

  def self.update(user:, id:, active: nil, attributes: nil)
    user.with_lock do
      rule = user.alert_rules.retained.find(id)
      ensure_setting!(rule)
      apply(user:, rule:, attributes: attributes || { active: })
    end
  end

  def self.archive(user:, id:)
    user.with_lock do
      rule = user.alert_rules.find(id)
      rule.update!(active: false)
      ensure_setting!(rule)
      rule.setting.update!(archived_at: rule.setting.archived_at || Time.current)
      rule
    end
  end

  def self.apply(user:, rule:, attributes:)
    if attributes[:frequency]
      if attributes[:frequency] == "instant" && !PlanCatalog.limit_for(user, :instant_alerts)
        raise PlanCatalog::Required.new(feature: "instant_alerts", limit: 0)
      end
      if rule.active? && attributes[:active] != false && rule.setting.frequency != attributes[:frequency]
        raise InvalidConfiguration, "Pause the rule before changing frequency"
      end
      rule.setting.update!(frequency: attributes[:frequency])
    end
    if attributes[:active]
      raise InvalidConfiguration, "This watchlist item has been removed" if rule.follow.removed_at
      if rule.setting&.frequency == "instant" && !PlanCatalog.limit_for(user, :instant_alerts)
        raise PlanCatalog::Required.new(feature: "instant_alerts", limit: 0)
      end
      preference = user.notification_preference
      raise InvalidConfiguration, "Set a time zone and enable email in notification preferences first" unless preference&.email_enabled? && preference.time_zone.present?
      limit = PlanCatalog.limit_for(user, :alert_rules)
      raise PlanCatalog::Required.new(feature: "alert_rules", limit:) if limit && user.alert_rules.retained.count > limit
    end
    rule.update!(active: attributes[:active]) if attributes.key?(:active)
    rule
  end

  def self.assert_slot!(user)
    limit = PlanCatalog.limit_for(user, :alert_rules)
    raise PlanCatalog::Required.new(feature: "alert_rules", limit:) if limit && user.alert_rules.retained.count >= limit
  end

  def self.ensure_setting!(rule)
    return if rule.setting

    rule.update!(active: false)
    rule.create_setting!(frequency: "instant", enabled_at: rule.created_at)
  end
end
