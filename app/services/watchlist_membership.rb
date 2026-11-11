# frozen_string_literal: true

class WatchlistMembership
  Result = Data.define(:follow, :created)

  def self.add(user:, target:, create_alert_rule: false)
    user.with_lock do
      existing = user.follows.find_by(target_type: target.type, target_key: target.key)
      return Result.new(follow: existing, created: false) if existing && existing.removed_at.nil?

      limit = PlanCatalog.limit_for(user, :watchlist_items)
      if limit && user.follows.current.count >= limit
        raise PlanCatalog::Required.new(feature: "watchlist_items", limit:)
      end
      if existing
        existing.update!(removed_at: nil, followed_at: Time.current)
        return Result.new(follow: existing, created: true)
      end
      follow = user.follows.create!(target_type: target.type, target_key: target.key,
                                    skip_default_alert_rule: !create_alert_rule)
      Result.new(follow:, created: true)
    end
  end

  def self.remove(user:, id:)
    user.with_lock do
      follow = user.follows.current.find(id)
      AlertRule.where(follow_id: follow.id).find_each { |rule| AlertRuleControl.archive(user:, id: rule.id) }
      follow.update!(removed_at: Time.current)
    end
  end
end
