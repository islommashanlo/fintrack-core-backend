# frozen_string_literal: true

class AlertRuleControl
  Result = Data.define(:rule, :created)
  class InvalidConfiguration < StandardError; end

  def self.create(user:, follow_id:, attributes:)
    user.with_lock do
      follow = user.follows.current.find(follow_id)
      trigger = attributes.fetch(:event_type, "new_filing")
      rule = follow.alert_rules.find_by(event_type: trigger, channel: "email")
      existing = rule && rule.setting&.archived_at.nil?
      assert_slot!(user) unless existing
      rule ||= follow.alert_rules.create!(event_type: trigger, active: false)
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
    if attributes[:event_type] && attributes[:event_type] != rule.event_type
      raise InvalidConfiguration, "Create a separate rule for another trigger"
    end
    configuration = attributes.slice(:frequency, :conditions).reject { |key, value| rule.setting.public_send(key) == value }
    if configuration.any? && rule.active? && attributes[:active] != false
      raise InvalidConfiguration, "Pause the rule before changing its configuration"
    end
    if attributes[:frequency] == "instant" && !PlanCatalog.limit_for(user, :instant_alerts)
      raise PlanCatalog::Required.new(feature: "instant_alerts", limit: 0)
    end
    if configuration.any?
      rule.setting.update!(**configuration, revision: rule.setting.revision + 1, enabled_at: Time.current)
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
