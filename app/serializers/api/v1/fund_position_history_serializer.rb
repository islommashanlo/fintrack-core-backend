# frozen_string_literal: true

module Api
  module V1
    class FundPositionHistorySerializer
      def self.render(row, sources:, as_of:)
        FilingProvenance.render(sources.fetch(row.id).filing, as_of:).merge(
          period_of_report: row.period_of_report, cusip: row["cusip"], put_call: row["put_call"], share_type: row["share_type"],
          status: row["status"], position: row["position"], portfolio: row["portfolio"],
          sources: row["source_ids"].map { |id| FilingProvenance.render(sources.fetch(id).filing, as_of:) }
        )
      end
    end
  end
end
