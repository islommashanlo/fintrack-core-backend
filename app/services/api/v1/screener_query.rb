# frozen_string_literal: true

module Api
  module V1
    class ScreenerQuery
      BOUNDS = { "filings" => Filing, "transactions" => InsiderTransaction, "funds" => InstitutionalFiler,
                 "reports" => InstitutionalReport, "holdings" => InstitutionalHolding }.freeze

      def self.call(page:, values:, maximum_records:)
        source = if values.fetch("entity") == "funds"
          ScreenerFundsQuery.new(page:).to_sql
        else
          ScreenerForm4Query.new(entity: values.fetch("entity"), page:, window_days: values.fetch("window_days").to_i).to_sql
        end
        predicate = ScreenerCompiler.call(entity: values.fetch("entity"), filters: values.fetch("filters"))
        result = page.call_sql("SELECT activity.* FROM (#{source}) activity WHERE #{predicate}", maximum_records:)
        CursorPage::Result.new(records: result.records, meta: result.meta.merge(
          entity: values.fetch("entity"), window_days: values["window_days"]&.to_i,
          truncated: maximum_records ? result.meta.fetch(:total_count) > maximum_records : false,
          feature: "screener_results", preview_limit: maximum_records,
          scoring_available: false, sector_available: false
        ))
      end
    end
  end
end
