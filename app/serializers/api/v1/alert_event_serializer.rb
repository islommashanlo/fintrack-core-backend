# frozen_string_literal: true

module Api
  module V1
    class AlertEventSerializer
      def self.render(delivery, as_of: Time.current)
        rule = delivery.alert_rule
        FilingProvenance.render(delivery.filing, as_of:).merge(
          id: delivery.id, rule_id: rule.id, trigger: rule.event_type,
          entity: { type: WatchlistTarget::API_TYPES.fetch(rule.follow.target_type), key: rule.follow.target_key },
          channel: rule.channel, frequency: delivery.frequency, status: delivery.status, read_at: delivery["api_read_at"],
          error_code: delivery.status == "failed" ? "DELIVERY_FAILED" : nil,
          delivered_at: delivery.delivered_at, created_at: delivery.created_at,
          updated_at: delivery.updated_at, period_of_report: delivery.filing.period_of_report
        )
      end
    end
  end
end
