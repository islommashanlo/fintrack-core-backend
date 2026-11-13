# frozen_string_literal: true

module Api
  module V1
    class FundTurnoverSerializer
      def self.context
        { baseline_policy: "adjacent_calendar_quarter",
          methodology_version: ActivityMethodology.definition.fetch("reported_allocation_turnover").fetch("version") }
      end

      def self.render(row:, sources:, fund:, period:, as_of:)
        primary = row && row["primary_report_id"]
        provenance = if primary
          FilingProvenance.render(sources.fetch(primary).filing, as_of:)
        else
          %i[accession form_type sec_url filed_at accepted_at ingested_at data_age_days].index_with { nil }
        end
        reason = row ? row["unavailable_reason"] : "no_current_report"
        percent = row && row["turnover_percent"]
        percent = BigDecimal(percent) if percent.is_a?(String)
        provenance.merge(fund: FundSerializer.render(fund), period_of_report: period,
          prior_period_of_report: period && (period << 3).end_of_quarter,
          status: reason ? "unavailable" : "available", unavailable_reason: reason,
          reported_allocation_turnover_percent: percent,
          current_portfolio: portfolio(row, "current", period, sources, as_of),
          prior_portfolio: portfolio(row, "prior", period && (period << 3).end_of_quarter, sources, as_of))
      end

      def self.portfolio(row, side, period, sources, as_of)
        metadata = row ? row.fetch("#{side}_portfolio") : {
          "complete" => false, "report_count" => 0, "report_ids" => [], "incomplete_report_ids" => [],
          "holding_row_count" => 0, "position_count" => 0, "known_value_usd" => nil, "total_value_usd" => nil
        }
        metadata.merge("period_of_report" => period,
          "source_scope" => metadata.fetch("report_count").positive? ? "effective_holdings" : "observed_reports",
          "sources" => (row ? row.fetch("#{side}_source_ids") : []).map { |id| FilingProvenance.render(sources.fetch(id).filing, as_of:) })
      end
      private_class_method :portfolio
    end
  end
end
