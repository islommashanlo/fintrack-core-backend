# frozen_string_literal: true

module Api
  module V1
    class FundTurnoverQuery
      def initialize(fund:, history:, as_of:, period: nil, bounds: nil)
        @fund, @history, @as_of = fund, history, as_of
        @explicit_period = period.present?
        @bounds = (bounds || InstitutionalHoldingsQuery::BOUNDS.transform_values { |model| model.maximum(:id) || 0 })
          .slice(*InstitutionalHoldingsQuery::BOUNDS.keys).freeze
        reports = InstitutionalReportScope.new(as_of:, max_report_id: @bounds.fetch("reports"),
          max_filing_id: @bounds.fetch("filings"), report_ids: InstitutionalReport.where(institutional_filer_id: fund.id).select(:id))
        @period = period || reports.visible_reports.except(:select).maximum(:period_of_report)
      end

      def call
        @history.check!(@period, as_of: @as_of)
        row = @period ? CursorPage.sql_rows(sql).sole : nil
        ids = row ? row.fetch("current_source_ids") + row.fetch("prior_source_ids") : []
        sources = InstitutionalReport.where(id: ids).includes(:filing).index_by(&:id)
        {
          data: FundTurnoverSerializer.render(row:, sources:, fund: @fund, period: @period, as_of: @as_of),
          meta: { as_of: @as_of.iso8601(6), period_selection: @explicit_period ? "explicit" : "latest_report",
            history_quarters: @history.context.fetch("history_quarters"), earliest_period: @history.earliest(as_of: @as_of),
            disclaimer: FilingsIntel::DISCLAIMER }.merge(FundTurnoverSerializer.context)
        }
      end

      private

      def sql
        periods = ApplicationRecord.sanitize_sql([ "SELECT ?::bigint AS institutional_filer_id, ?::date AS period_of_report", @fund.id, @period ])
        FundTurnoverSql.new(periods:, bounds: @bounds, as_of: @as_of).to_sql
      end
    end
  end
end
