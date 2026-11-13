# frozen_string_literal: true

module Api
  module V1
    class FundDirectorySerializer
      def self.render(fund, sources:, as_of:)
        reports = fund["source_report_ids"].map { |id| sources.fetch(id) }
        portfolio = if reports.any?
          FilingProvenance.render(reports.first.filing, as_of:).merge(period_of_report: fund["period_of_report"],
            complete: fund["portfolio_complete"], value_usd: fund["portfolio_value_usd"], position_count: fund["position_count"],
            holding_row_count: fund["holding_row_count"], effective_report_count: fund["effective_report_count"],
            sources: reports.map { |report| FilingProvenance.render(report.filing, as_of:) })
        end
        FundSerializer.render(fund).merge(reported_portfolio: portfolio, portfolio_unavailable_reason: fund["portfolio_unavailable_reason"])
      end
    end
  end
end
