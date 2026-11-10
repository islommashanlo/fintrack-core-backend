# frozen_string_literal: true

module Api
  module V1
    class PositionChangeSerializer
      CHANGE_TYPES = { "new" => "new", "add" => "added", "trim" => "reduced", "exit" => "exited" }.freeze

      def self.render(change, reports:, as_of: Time.current)
        report = reports.fetch(change["current_report_id"])
        FilingProvenance.render(report.filing, as_of:).merge(
          period_of_report: change.period_of_report, prior_period_of_report: change.prior_period_of_report,
          cusip: change.cusip, put_call: change.put_call, share_type: change.share_type,
          issuer_name: change.name_of_issuer, title_of_class: change.title_of_class,
          change_type: CHANGE_TYPES.fetch(change.change_type),
          shares_before: change.shares_before, shares_after: change.shares_after, shares_delta: change.shares_delta,
          value_usd_before: change.value_usd_before, value_usd_after: change.value_usd_after,
          value_usd_delta: change.value_usd_delta, current_suspect: change.current_suspect, prior_suspect: change.prior_suspect,
          current_sources: Array(change["current_report_ids"]).map { |id| FilingProvenance.render(reports.fetch(id).filing, as_of:) },
          prior_sources: Array(change["prior_report_ids"]).map { |id| FilingProvenance.render(reports.fetch(id).filing, as_of:) }
        )
      end
    end
  end
end
