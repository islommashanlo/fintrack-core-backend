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
        scope = scope.where(event_type: filters["trigger"]) if filters["trigger"]
        scope = scope.where(alert_rule_id: filters["rule_id"]) if filters["rule_id"]
        scope = scope.where(follows: { target_type: WatchlistTarget::TYPES.fetch(filters["entity_type"]) }) if filters["entity_type"]
        scope = scope.where("alert_deliveries.created_at >= ?", Date.iso8601(filters["date_from"], Date::GREGORIAN).beginning_of_day) if filters["date_from"]
        scope = scope.where("alert_deliveries.created_at < ?", Date.iso8601(filters["date_to"], Date::GREGORIAN).next_day.beginning_of_day) if filters["date_to"]
        sql = ApplicationRecord.sanitize_sql([ <<~SQL, user: user.id ])
          SELECT alert_deliveries.*, state.read_at AS api_read_at FROM (#{scope.to_sql}) alert_deliveries
          LEFT JOIN alert_event_states state ON state.alert_delivery_id = alert_deliveries.id AND state.user_id = :user
        SQL
        projected = AlertDelivery.from("(#{sql}) alert_deliveries")
        projected = projected.where("api_read_at IS #{filters['unread'] == 'true' ? '' : 'NOT '}NULL") if filters["unread"]
        page.call(projected, preload: [ :filing, :insider_cluster_snapshot, :news_alert_snapshot, { institutional_change_snapshot: [ :primary_filing, :institutional_filer ] },
          { alert_rule: :follow }, { insider_transaction: :filing } ])
      end
    end
  end
end
