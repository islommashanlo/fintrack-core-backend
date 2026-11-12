# frozen_string_literal: true

module Api
  module V1
    class InAppNotificationSerializer
      def self.render(record, as_of: Time.current)
        rule = record.alert_rule
        FilingProvenance.render(record.filing, as_of:).merge(
          id: record.id, rule_id: rule.id, trigger: "new_filing", channel: "in_app",
          entity: { type: WatchlistTarget::API_TYPES.fetch(rule.follow.target_type), key: rule.follow.target_key },
          published_at: record.published_at, read_at: record.read_at, created_at: record.created_at,
          historical_filing_notice: true
        )
      end
    end
  end
end
