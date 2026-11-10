# frozen_string_literal: true

class WatchlistMembership
  Result = Data.define(:follow, :created)

  def self.add(user:, target:, create_alert_rule: false)
    user.with_lock do
      existing = user.follows.find_by(target_type: target.type, target_key: target.key)
      return Result.new(follow: existing, created: false) if existing

      limit = PlanCatalog.limit_for(user, :watchlist_items)
      if limit && user.follows.count >= limit
        raise PlanCatalog::Required.new(feature: "watchlist_items", limit:)
      end
      follow = user.follows.create!(target_type: target.type, target_key: target.key,
                                    skip_default_alert_rule: !create_alert_rule)
      Result.new(follow:, created: true)
    end
  end

  def self.remove(user:, id:)
    user.with_lock do
      follow = user.follows.find(id)
      AlertDelivery.where(alert_rule_id: AlertRule.where(follow_id: follow.id).select(:id)).delete_all
      follow.destroy!
    end
  end
end
