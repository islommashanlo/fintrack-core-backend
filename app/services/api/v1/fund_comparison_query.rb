# frozen_string_literal: true

module Api
  module V1
    class FundComparisonQuery
      BOUNDS = InstitutionalHoldingsQuery::BOUNDS.merge("funds" => InstitutionalFiler).freeze
      SORTS = { "holders" => "activity.holder_count", "cusip" => "activity.cusip" }.freeze

      def initialize(page:, filters:, period:, history_quarters:)
        @page, @filters, @history = page, filters, history_quarters
        ciks = filters.fetch("ciks").split(",")
        @funds = InstitutionalFiler.where(cik: ciks).where("id <= ?", page.bound("funds")).order(:cik).to_a
        raise ActiveRecord::RecordNotFound unless @funds.size == ciks.size
        @reports = InstitutionalReportScope.new(as_of: page.as_of, max_report_id: page.bound("reports"),
          max_filing_id: page.bound("filings"), max_holding_id: page.bound("holdings"),
          report_ids: InstitutionalReport.where(institutional_filer_id: @funds.map(&:id)).select(:id))
        chosen = page.snapshot_value("comparison_period") { (period || latest_common_period)&.iso8601 }
        @period = chosen && Date.iso8601(chosen)
        if @period && @history
          earliest = ((page.as_of.to_date.beginning_of_quarter - 1.day) << ((@history - 1) * 3)).end_of_quarter
          raise PlanCatalog::Required.new(feature: "history_quarters", limit: @history) if @period < earliest
        end
      end

      def call
        sql = FundComparisonSql.new(page: @page, funds: @funds, reports: @reports, period: @period)
        states = CursorPage.sql_rows(sql.fund_states)
        raise ActiveRecord::RecordNotFound unless states.size == @funds.size
        pairs = CursorPage.sql_rows(sql.overlaps)
        result = @page.call_sql(sql.positions(@filters))
        serializer = FundComparisonSerializer.new(states:, as_of: @page.as_of)
        coverage = states.first
        available = coverage.fetch("any_current_report")
        { data: { funds: states.map { |row| serializer.fund(row) },
          overlaps: pairs.map { |row| serializer.overlap(row) }, positions: result.records.map { |row| serializer.position(row) } },
          meta: result.meta.merge(period_of_report: @period, prior_period_of_report: @period && (@period << 3).end_of_quarter,
            period_selection: @filters["period"] ? "explicit" : "latest_common", available:,
            unavailable_reason: available ? nil : (@period ? "no_current_reports" : "no_common_period"),
            complete: coverage.fetch("comparison_complete"), prior_complete: coverage.fetch("comparison_prior_complete"),
            security_key: %w[cusip put_call share_type], disclaimer: FilingsIntel::DISCLAIMER) }
      end

      private

      def latest_common_period
        @reports.effective_reports.where(institutional_filer_id: @funds.map(&:id))
          .where("period_of_report <= ?", @page.as_of.to_date).group(:period_of_report)
          .having("COUNT(DISTINCT institutional_filer_id) = ?", @funds.size)
          .order(period_of_report: :desc).limit(1).pluck(:period_of_report).first
      end
    end
  end
end
