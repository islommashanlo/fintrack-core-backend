# frozen_string_literal: true

module Api
  module V1
    class AlertEventSerializer
      def initialize(deliveries:, as_of:)
        @as_of = as_of
        rows = deliveries.filter_map(&:insider_cluster_snapshot).map(&:attributes)
        @clusters = InsiderClusterSerializer.new(rows:, as_of:)
        @institutional = InstitutionalAlertSerializer.new(snapshots: deliveries.filter_map(&:institutional_change_snapshot), as_of:)
      end

      def render(delivery)
        rule = delivery.alert_rule
        as_of = @as_of
        snapshot = delivery.insider_cluster_snapshot
        FilingProvenance.render(delivery.filing, as_of:).merge(
          id: delivery.id, rule_id: rule.id, trigger: delivery.event_type,
          transaction: delivery.insider_transaction && InsiderTransactionSerializer.render(delivery.insider_transaction, as_of:),
          cluster: snapshot && @clusters.render(snapshot.attributes).merge(observed_at: snapshot.observed_at,
            definition_minimum_insiders: snapshot.definition_minimum_insiders),
          position_change: delivery.institutional_change_snapshot && @institutional.render(delivery.institutional_change_snapshot),
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
