# frozen_string_literal: true

module Api
  module V1
    class CompanyHistoryQuery
      BOUNDS = InstitutionalHoldingsQuery::BOUNDS.merge("mappings" => CusipSecurityMapping, "securities" => Security).freeze
      SORTS = { "period" => "institutional_reports.period_of_report", "holders" => "institutional_reports.holder_count" }.freeze

      def initialize(ticker:, page:, filters:, history:)
        @ticker, @page, @filters, @history = ticker, page, filters, history
      end

      def call
        period = @filters["period"] && Date.iso8601(@filters["period"])
        @history.check!(period, as_of: @page.as_of)
        sql = CompanyHistorySql.new(page: @page, ticker: @ticker, filters: @filters)
        coverage = CursorPage.sql_rows(sql.coverage).first
        # Quarter projections use a stable synthetic ID and are never persisted.
        scope = InstitutionalReport.from("(#{sql.timeline}) institutional_reports")
        scope = scope.where(period_of_report: period) if period
        result = @history.preview(page: @page, scope:, allowed_scope: @history.reports(scope, as_of: @page.as_of))
        available = coverage.fetch("mapping_count").positive? && coverage.fetch("cohort_fund_count").positive?
        CursorPage::Result.new(records: result.records, meta: result.meta.merge(ticker: @ticker,
          available:, unavailable_reason: available ? nil : (coverage.fetch("mapping_count").zero? ? "mapping_unavailable" : "no_local_holdings"),
          cohort_fund_count: coverage.fetch("cohort_fund_count"), cohort_basis: "ever_reported_in_effective_local_holdings",
          mapping_policy: "current_local_cache", missing_periods_filled: false, marketwide_ownership_available: false,
          source_limit: CompanyHistorySql::SOURCE_LIMIT, position_limit: CompanyHistorySql::POSITION_LIMIT,
          disclaimer: FilingsIntel::DISCLAIMER))
      end
    end
  end
end
