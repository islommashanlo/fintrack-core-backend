# frozen_string_literal: true

module Api
  module V1
    class AlertRulesQuery
      SORTS = { "created_at" => "alert_rules.created_at", "active" => "alert_rules.active", "entity_key" => "follows.target_key" }.freeze
      BOUNDS = { "rules" => AlertRule, "follows" => Follow }.freeze

      def self.call(user:, page:, filters:)
        scope = user.alert_rules.retained.where("alert_rules.id <= ? AND follows.id <= ? AND alert_rules.created_at <= ?",
          page.bound("rules"), page.bound("follows"), page.as_of)
        scope = scope.where(active: filters["active"] == "true") if filters["active"]
        scope = scope.where(follows: { target_type: WatchlistTarget::TYPES.fetch(filters["entity_type"]) }) if filters["entity_type"]
        page.call(scope, preload: [ :follow, :setting ])
      end
    end
  end
end
