# frozen_string_literal: true

module Api
  module V1
    class ScreenerExecution
      Result = Data.define(:rows, :meta)

      def self.call(values:, user:, as_of:, export: false)
        maximum = PlanCatalog.limit_for(user, :screener_results)
        context = { "resource" => export ? "screener_export" : "screener", "user_id" => user&.id, "maximum_records" => maximum }
        context.merge!("csv_export" => true, "export_version" => 1) if export
        history = if values.fetch("entity") == "funds"
          HistoryWindow.new(limit: PlanCatalog.limit_for(user, :history_quarters), user_id: user&.id)
        end
        context.merge!(history.context).merge!("fund_metrics_version" => 3) if history
        # Keep legal multi-value filters out of the bounded continuation header.
        pagination = export ? values.except("filters").merge("filters_digest" => Digest::SHA256.hexdigest(JSON.generate(values.fetch("filters")))) : values
        page = CursorPage.new(parameters: pagination, context:, sorts: ScreenerDefinition.sorts(values.fetch("entity")),
          default_sort: "name", bounds: ScreenerQuery::BOUNDS, as_of:, maximum_limit: export ? ExportQuery::MAX_ROWS : ScreenerInputRules::PAGE_RANGE.end)
        result = ScreenerQuery.call(page:, values:, maximum_records: maximum, history:)
        serializer = ScreenerResultSerializer.new(rows: result.records, entity: values.fetch("entity"), as_of: page.as_of,
          window_days: values["window_days"]&.to_i)
        Result.new(rows: result.records.map { |row| serializer.render(row) }, meta: result.meta)
      end
    end
  end
end
