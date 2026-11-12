# frozen_string_literal: true

module Api
  module V1
    class InAppNotificationSerializer
      def initialize(records:, as_of:)
        @as_of = as_of
        @news = NewsAlertSerializer.new(snapshots: records.filter_map(&:news_alert_snapshot), as_of:)
        @institutional = InstitutionalAlertSerializer.new(snapshots: records.filter_map(&:institutional_change_snapshot), as_of:)
        @clusters = InsiderClusterSerializer.new(rows: records.filter_map(&:insider_cluster_snapshot).map(&:attributes), as_of:)
      end

      def render(record)
        as_of = @as_of
        snapshot = record.insider_cluster_snapshot
        rule = record.alert_rule
        provenance = record.filing ? FilingProvenance.render(record.filing, as_of:) :
          { accession: nil, sec_url: nil, form_type: nil, filed_at: nil, accepted_at: nil, ingested_at: nil, data_age_days: nil }
        news = @news.render(record.news_alert_snapshot)
        provenance.merge(
          id: record.id, rule_id: rule.id, trigger: record.event_type, channel: "in_app",
          entity: { type: WatchlistTarget::API_TYPES.fetch(rule.follow.target_type), key: rule.follow.target_key },
          published_at: record.published_at, read_at: record.read_at, created_at: record.created_at,
          historical_filing_notice: record.event_type != "news", news:, news_available: record.event_type == "news" ? news.present? : nil,
          transaction: record.insider_transaction && InsiderTransactionSerializer.render(record.insider_transaction, as_of:),
          position_change: record.institutional_change_snapshot && @institutional.render(record.institutional_change_snapshot),
          cluster: snapshot && @clusters.render(snapshot.attributes).merge(observed_at: snapshot.observed_at,
            definition_minimum_insiders: snapshot.definition_minimum_insiders)
        )
      end
    end
  end
end
