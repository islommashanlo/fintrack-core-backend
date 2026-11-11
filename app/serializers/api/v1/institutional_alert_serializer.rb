# frozen_string_literal: true

module Api
  module V1
    class InstitutionalAlertSerializer
      def initialize(snapshots:, as_of:)
        @as_of = as_of
        ids = snapshots.flat_map(&:evidence_report_ids)
        @reports = InstitutionalReport.where(id: ids).includes(:filing).index_by(&:id)
      end

      def render(snapshot)
        FilingProvenance.render(snapshot.primary_filing, as_of: @as_of).merge(
          id: "institutional_change_#{snapshot.event_key}", observed_at: snapshot.observed_at,
          fund: { cik: snapshot.institutional_filer.cik, name: snapshot.institutional_filer.name },
          period_of_report: snapshot.period_of_report, prior_period_of_report: snapshot.prior_period_of_report,
          cusip: snapshot.cusip, put_call: snapshot.put_call, share_type: snapshot.share_type,
          issuer_name: snapshot.name_of_issuer, title_of_class: snapshot.title_of_class,
          change_type: PositionChangeSerializer::CHANGE_TYPES.fetch(snapshot.change_type),
          direction: snapshot.change_type.in?(%w[new add]) ? "increase" : "decrease",
          **snapshot.attributes.slice("shares_before", "shares_after", "shares_delta", "value_usd_before", "value_usd_after", "value_usd_delta",
            "current_suspect", "prior_suspect", "values_complete"),
          current_sources: sources(snapshot.current_report_ids), prior_sources: sources(snapshot.prior_report_ids),
          evidence_sources: sources(snapshot.evidence_report_ids)
        )
      end

      private

      def sources(ids)
        ids.map { |id| FilingProvenance.render(@reports.fetch(id).filing, as_of: @as_of) }
      end
    end
  end
end
