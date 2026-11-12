# frozen_string_literal: true

module Api
  module V1
    class PositionChangesQuery
      SORTS = {
        "value_change" => "ABS(position_diffs.value_usd_delta)", "shares_change" => "ABS(position_diffs.shares_delta)",
        "cusip" => "position_diffs.cusip"
      }.freeze

      attr_reader :period

      def initialize(fund:, page:, period: nil, change_type: nil)
        @fund = fund
        @page = page
        @reports = InstitutionalReportScope.new(as_of: page.as_of, max_report_id: page.bound("reports"),
                                                max_filing_id: page.bound("filings"))
        chosen = page.snapshot_value("changes_period") do
          (period || @reports.visible_reports.where(institutional_filer_id: fund.id).except(:select).maximum(:period_of_report))&.iso8601
        end
        @period = chosen && Date.iso8601(chosen)
        @change_type = PositionChangeSerializer::CHANGE_TYPES.key(change_type)
        raise InvalidParameter, "Invalid change_type parameter" if change_type && !@change_type
      end

      def call
        return @page.call(PositionDiff.none) unless @period

        sql = InstitutionalPositionDiffQuery.new(institutional_filer_id: @fund.id, period_of_report: @period,
          report_scope: @reports, max_holding_id: @page.bound("holdings")).to_sql
        scope = PositionDiff.from(<<~SQL.squish)
          (SELECT ROW_NUMBER() OVER (ORDER BY cusip, put_call NULLS FIRST, share_type) AS id, derived.*
           FROM (#{sql}) derived) position_diffs
        SQL
        scope = scope.where(change_type: @change_type) if @change_type
        @page.call(scope)
      end

      def prior_period
        return @prior_period if defined?(@prior_period)

        @prior_period = if @period
          @reports.effective_reports.where(institutional_filer_id: @fund.id)
            .where("institutional_reports.period_of_report < ?", @period).maximum(:period_of_report)
        end
      end

      def portfolios(records)
        { current: @period, prior: prior_period }.transform_values do |period|
          FundPortfolioQuery.new(page: @page, reports: @reports, fund: @fund, period:).for_positions(records)
        end
      end

      def self.sources(records)
        ids = records.flat_map { |change| Array(change["current_report_ids"]) + Array(change["prior_report_ids"]) }
        InstitutionalReport.where(id: ids).includes(:filing).index_by(&:id)
      end
    end
  end
end
