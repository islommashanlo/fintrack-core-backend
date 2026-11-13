# frozen_string_literal: true

module Api
  module V1
    class FundDirectorySerializer
      def self.render(fund, sources:, as_of:, turnover_context: nil)
        reports = fund["source_report_ids"].map { |id| sources.fetch(id) }
        portfolio = if reports.any?
          FilingProvenance.render(reports.first.filing, as_of:).merge(period_of_report: fund["period_of_report"],
            complete: fund["portfolio_complete"], value_usd: fund["portfolio_value_usd"], position_count: fund["position_count"],
            holding_row_count: fund["holding_row_count"], effective_report_count: fund["effective_report_count"],
            report_types: reports.map(&:report_type).uniq.sort,
            sources: reports.map { |report| FilingProvenance.render(report.filing, as_of:).merge(report_type: report.report_type) })
        end
        result = FundSerializer.render(fund).merge(reported_portfolio: portfolio, portfolio_unavailable_reason: fund["portfolio_unavailable_reason"])
        if fund.has_attribute?("turnover_record")
          result[:reported_allocation_turnover] = turnover(fund, sources:, as_of:, context: turnover_context || FundTurnoverSerializer.context)
        end
        result
      end

      def self.turnover(fund, sources:, as_of:, context:)
        if fund["portfolio_unavailable_reason"] == "history_restricted"
          return FundTurnoverSummarySerializer.history_restricted(period: nil, context:)
        end

        row = fund["turnover_record"]
        period = row && Date.iso8601(row.fetch("period_of_report"))
        data = FundTurnoverSerializer.render(row:, sources:, fund:, period:, as_of:)
        FundTurnoverSummarySerializer.render(data:, meta: context)
      end
      private_class_method :turnover
    end
  end
end
