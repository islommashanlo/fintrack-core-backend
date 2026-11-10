# frozen_string_literal: true

module Api
  module V1
    class AlertEventsQuery
      SORTS = { "created_at" => "alert_deliveries.created_at", "delivered_at" => "alert_deliveries.delivered_at", "status" => "alert_deliveries.status" }.freeze
      BOUNDS = { "deliveries" => AlertDelivery, "rules" => AlertRule, "follows" => Follow }.freeze

      def self.call(user:, page:, filters:)
        scope = user.alert_deliveries.where(<<~SQL.squish, page.bound("deliveries"), page.bound("rules"), page.bound("follows"), page.as_of)
          alert_deliveries.id <= ? AND alert_rules.id <= ? AND follows.id <= ? AND alert_deliveries.created_at <= ?
        SQL
        scope = scope.where(status: filters["status"]) if filters["status"]
        scope = scope.where(alert_rule_id: filters["rule_id"]) if filters["rule_id"]
        scope = scope.where(follows: { target_type: WatchlistTarget::TYPES.fetch(filters["entity_type"]) }) if filters["entity_type"]
        scope = scope.where("alert_deliveries.created_at >= ?", Date.iso8601(filters["date_from"], Date::GREGORIAN).beginning_of_day) if filters["date_from"]
        scope = scope.where("alert_deliveries.created_at < ?", Date.iso8601(filters["date_to"], Date::GREGORIAN).next_day.beginning_of_day) if filters["date_to"]
        page.call(scope, preload: [ :filing, { alert_rule: :follow } ])
      end
    end
  end
end
