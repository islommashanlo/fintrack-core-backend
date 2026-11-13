# frozen_string_literal: true

module Api
  module V1
    class FundProfileQuery
      def initialize(fund:, history:, as_of:)
        @fund, @history = fund, history
        @page = CursorPage.new(parameters: {}, context: history.context.merge("resource" => "fund_profile", "cik" => fund.cik),
          sorts: FundDirectoryQuery::SORTS, default_sort: "name", bounds: InstitutionalHoldingsQuery::BOUNDS,
          captured_bounds: InstitutionalHoldingsQuery::BOUNDS.transform_values { |model| model.maximum(:id) || 0 }.merge("funds" => fund.id), as_of:)
      end

      def call
        sql = FundDirectorySql.new(page: @page, history: @history, period: nil, fund_id: @fund.id).to_sql
        projection = InstitutionalFiler.from("(#{sql}) institutional_filers").find(@fund.id)
        sources = FundDirectoryQuery.sources([ projection ])
        latest = InstitutionalReportScope.new(as_of: @page.as_of, max_report_id: @page.bound("reports"), max_filing_id: @page.bound("filings"))
          .visible_reports.where(institutional_filer_id: @fund.id).order(period_of_report: :desc)
          .order(Arel.sql("known_filed_at DESC, known_accession DESC")).preload(:filing).first
        {
          data: FundDirectorySerializer.render(projection, sources:, as_of: @page.as_of).merge(
            latest_report: latest && InstitutionalReportSerializer.render(latest, as_of: @page.as_of),
            reported_allocation_turnover: turnover(latest, projection["portfolio_unavailable_reason"])),
          meta: { as_of: @page.as_of.iso8601(6), history_quarters: @history.context.fetch("history_quarters"),
            earliest_period: @history.earliest(as_of: @page.as_of), portfolio_history_limited: !@history.earliest(as_of: @page.as_of).nil?,
            portfolio_period: "latest_per_fund", value_is_aum: false, disclaimer: FilingsIntel::DISCLAIMER }
        }
      end

      private

      def turnover(latest, portfolio_reason)
        if portfolio_reason == "history_restricted"
          return FundTurnoverSummarySerializer.history_restricted(period: latest.period_of_report)
        end

        bounds = InstitutionalHoldingsQuery::BOUNDS.keys.index_with { |key| @page.bound(key) }
        result = FundTurnoverQuery.new(fund: @fund, history: @history, as_of: @page.as_of,
          period: latest&.period_of_report, bounds:).call
        FundTurnoverSummarySerializer.render(result)
      end
    end
  end
end
