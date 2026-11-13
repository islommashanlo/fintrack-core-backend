# frozen_string_literal: true

class AlertRuleControl
  Result = Data.define(:rule, :created)
  class InvalidConfiguration < StandardError; end

  def self.create(user:, follow_id: nil, attributes:)
    user.with_lock do
      target_scope = attributes.fetch(:scope, "follow")
      unless AlertRule::SCOPES.include?(target_scope) && (target_scope == "follow" || follow_id.nil?)
        raise InvalidConfiguration, "Invalid alert rule scope"
      end
      follow = user.follows.current.find(follow_id) if target_scope == "follow"
      candidates = user.alert_rules.where(scope: target_scope, follow_id: follow&.id)
      trigger = attributes.fetch(:event_type, "new_filing")
      channel = attributes.fetch(:channel, "email")
      rule = candidates.find_by(event_type: trigger, channel:)
      existing = rule && rule.setting&.archived_at.nil?
      same_logical_rule = candidates.retained.where(event_type: trigger).exists?
      assert_slot!(user) unless existing || same_logical_rule
      rule ||= candidates.create!(event_type: trigger, channel:, active: false)
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
    if rule.scope == "watchlist" && attributes[:active] && !rule.watchlist_activation_supported?
      raise InvalidConfiguration, "This watchlist trigger/channel cannot be activated yet"
    end
    if attributes[:scope] && attributes[:scope] != rule.scope
      raise InvalidConfiguration, "Create a separate rule for another scope"
    end
    if attributes[:channel] && attributes[:channel] != rule.channel
      raise InvalidConfiguration, "Create a separate rule for another channel"
    end
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
      raise InvalidConfiguration, "This watchlist item has been removed" if rule.scope == "follow" && rule.follow.removed_at
      if rule.setting&.frequency == "instant" && !PlanCatalog.limit_for(user, :instant_alerts)
        raise PlanCatalog::Required.new(feature: "instant_alerts", limit: 0)
      end
      preference = user.notification_preference
      if rule.channel == "email"
        raise InvalidConfiguration, "Set a time zone and enable email in notification preferences first" unless preference&.email_enabled? && preference.time_zone.present?
      elsif rule.setting.frequency == "daily_digest" && preference&.time_zone.blank?
        raise InvalidConfiguration, "Set a time zone for daily in-app notifications first"
      end
      limit = PlanCatalog.limit_for(user, :alert_rules)
      raise PlanCatalog::Required.new(feature: "alert_rules", limit:) if limit && AlertRuleQuota.count(user) > limit
    end
    rule.update!(active: attributes[:active]) if attributes.key?(:active)
    rule
  end

  def self.assert_slot!(user)
    limit = PlanCatalog.limit_for(user, :alert_rules)
    raise PlanCatalog::Required.new(feature: "alert_rules", limit:) if limit && AlertRuleQuota.count(user) >= limit
  end

  def self.ensure_setting!(rule)
    return if rule.setting

    rule.update!(active: false)
    rule.create_setting!(frequency: "instant", enabled_at: rule.created_at)
  end
end
