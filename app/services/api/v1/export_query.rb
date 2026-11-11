# frozen_string_literal: true

module Api
  module V1
    class ExportQuery
      MAX_ROWS = 1000
      PARAMETERS = {
        "insider-transactions" => InsiderTransactionsQuery::PARAMETERS,
        "fund-holdings" => %w[cik period cusip put_call share_type sort limit cursor],
        "fund-changes" => %w[cik period change_type sort limit cursor]
      }.freeze
      Result = Data.define(:rows, :meta)

      def initialize(dataset:, parameters:, user:, as_of:)
        @dataset, @user, @as_of = dataset, user, as_of
        @values = { "limit" => MAX_ROWS.to_s }.merge(parameters)
        @context = { "resource" => "csv_export", "dataset" => dataset, "user_id" => user.id, "csv_export" => true }
      end

      def call
        case @dataset
        when "insider-transactions" then transactions
        when "fund-holdings" then holdings
        when "fund-changes" then changes
        else raise ActiveRecord::RecordNotFound
        end
      end

      private

      def transactions
        result = InsiderTransactionsQuery.new(parameters: @values, as_of: @as_of,
          maximum_limit: MAX_ROWS, cursor_context: @context).call
        timestamp = Time.iso8601(result.meta.fetch(:as_of))
        Result.new(rows: result.records.map { |row| InsiderTransactionSerializer.render(row, as_of: timestamp) }, meta: result.meta)
      end

      def holdings
        fund = find_fund
        period = requested_period
        InstitutionalHoldingsQuery.validate_filters!(@values)
        page = report_page(sorts: InstitutionalHoldingsQuery::SORTS, default_sort: "-value_usd")
        query = InstitutionalHoldingsQuery.new(page:, filters: @values)
        scope = query.for_fund(fund, period:)
        @history.check!(query.period, as_of: page.as_of)
        result = page.call(scope, preload: [ { institutional_report: [ :filing, :institutional_filer ] } ])
        Result.new(rows: result.records.map { |row| InstitutionalHoldingSerializer.render(row, as_of: page.as_of) }, meta: result.meta)
      end

      def changes
        fund = find_fund
        period = requested_period
        page = report_page(sorts: PositionChangesQuery::SORTS, default_sort: "-value_change")
        query = PositionChangesQuery.new(fund:, page:, period:, change_type: @values["change_type"])
        @history.check!(query.period, as_of: page.as_of)
        result = query.call
        sources = PositionChangesQuery.sources(result.records)
        rows = result.records.map do |row|
          PositionChangeSerializer.render(row, reports: sources, as_of: page.as_of).merge(fund: { cik: fund.cik, name: fund.name })
        end
        Result.new(rows:, meta: result.meta)
      end

      def find_fund
        raise InvalidParameter, "Invalid cik parameter" unless @values["cik"]&.match?(/\A\d{10}\z/)
        InstitutionalFiler.find_by!(cik: @values.fetch("cik"))
      end

      def requested_period
        return unless @values["period"]
        period = Date.iso8601(@values["period"])
        raise Date::Error unless @values["period"] == period.iso8601 && period == period.end_of_quarter
        period
      rescue Date::Error
        raise InvalidParameter, "Invalid period parameter"
      end

      def report_page(sorts:, default_sort:)
        @history = HistoryWindow.new(limit: PlanCatalog.limit_for(@user, :history_quarters), user_id: @user.id)
        CursorPage.new(parameters: @values, context: @context.merge(@history.context), sorts:, default_sort:,
          bounds: InstitutionalHoldingsQuery::BOUNDS, as_of: @as_of, maximum_limit: MAX_ROWS)
      end
    end
  end
end
