# frozen_string_literal: true

module Api
  module V1
    class ScreenerQuery
      BOUNDS = { "filings" => Filing, "transactions" => InsiderTransaction, "funds" => InstitutionalFiler,
                 "reports" => InstitutionalReport, "holdings" => InstitutionalHolding }.freeze

      def self.call(page:, values:, maximum_records:, history:)
        source = if values.fetch("entity") == "funds"
          ScreenerFundsQuery.new(page:, history:).to_sql
        else
          ScreenerForm4Query.new(entity: values.fetch("entity"), page:, window_days: values.fetch("window_days").to_i).to_sql
        end
        predicate = ScreenerCompiler.call(entity: values.fetch("entity"), filters: values.fetch("filters"))
        result = page.call_sql("SELECT activity.* FROM (#{source}) activity WHERE #{predicate}", maximum_records:)
        turnover_context = history && FundTurnoverSerializer.context
        metadata = result.meta.merge(
          entity: values.fetch("entity"), window_days: values["window_days"]&.to_i,
          truncated: maximum_records ? result.meta.fetch(:total_count) > maximum_records : false,
          feature: "screener_results", preview_limit: maximum_records,
          scoring_available: false, sector_available: false
        )
        if history
          metadata.merge!(history_quarters: history.context.fetch("history_quarters"), earliest_period: history.earliest(as_of: page.as_of),
            fund_metrics_policy_version: 3, turnover_baseline_policy: turnover_context.fetch(:baseline_policy),
            turnover_methodology_version: turnover_context.fetch(:methodology_version),
            turnover_history_quarters: history.context.fetch("history_quarters"), turnover_earliest_period: history.earliest(as_of: page.as_of))
        end
        CursorPage::Result.new(records: result.records, meta: metadata)
      end
    end
  end
end
