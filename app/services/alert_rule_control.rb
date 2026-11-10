# frozen_string_literal: true

class AlertRuleControl
  def self.update(user:, id:, active:)
    user.with_lock do
      rule = user.alert_rules.find(id)
      if active
        unless PlanCatalog.limit_for(user, :instant_alerts)
          raise PlanCatalog::Required.new(feature: "instant_alerts", limit: 0)
        end
        limit = PlanCatalog.limit_for(user, :alert_rules)
        if !rule.active? && limit && user.alert_rules.active.count >= limit
          raise PlanCatalog::Required.new(feature: "alert_rules", limit:)
        end
      end
      rule.update!(active:)
      rule
    end
  end
end
