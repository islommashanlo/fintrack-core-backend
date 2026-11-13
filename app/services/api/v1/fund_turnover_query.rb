# frozen_string_literal: true

module Api
  module V1
    class FundTurnoverQuery
      def initialize(fund:, history:, as_of:, period: nil)
        @fund, @history, @as_of = fund, history, as_of
        @explicit_period = period.present?
        @bounds = InstitutionalHoldingsQuery::BOUNDS.transform_values { |model| model.maximum(:id) || 0 }
        reports = InstitutionalReportScope.new(as_of:, max_report_id: @bounds.fetch("reports"),
          max_filing_id: @bounds.fetch("filings"), report_ids: InstitutionalReport.where(institutional_filer_id: fund.id).select(:id))
        @period = period || reports.visible_reports.except(:select).maximum(:period_of_report)
        @prior = @period && (@period << 3).end_of_quarter
      end

      def call
        @history.check!(@period, as_of: @as_of)
        row = @period ? CursorPage.sql_rows(sql).sole : nil
        ids = row ? row.fetch("current_source_ids") + row.fetch("prior_source_ids") : []
        sources = InstitutionalReport.where(id: ids).includes(:filing).index_by(&:id)
        primary = row && row["primary_report_id"]
        provenance = if primary
          FilingProvenance.render(sources.fetch(primary).filing, as_of: @as_of)
        else
          %i[accession form_type sec_url filed_at accepted_at ingested_at data_age_days].index_with { nil }
        end
        reason = row ? row["unavailable_reason"] : "no_current_report"
        {
          data: provenance.merge(fund: FundSerializer.render(@fund), period_of_report: @period,
            prior_period_of_report: @prior, status: reason ? "unavailable" : "available", unavailable_reason: reason,
            reported_allocation_turnover_percent: row && row["turnover_percent"],
            current_portfolio: portfolio(row, "current", sources), prior_portfolio: portfolio(row, "prior", sources)),
          meta: { as_of: @as_of.iso8601(6), period_selection: @explicit_period ? "explicit" : "latest_report",
            baseline_policy: "adjacent_calendar_quarter", methodology_version: ActivityMethodology.definition.fetch("reported_allocation_turnover").fetch("version"),
            history_quarters: @history.context.fetch("history_quarters"), earliest_period: @history.earliest(as_of: @as_of),
            disclaimer: FilingsIntel::DISCLAIMER }
        }
      end

      private

      def portfolio(row, side, sources)
        metadata = row ? row.fetch("#{side}_portfolio") : {
          "complete" => false, "report_count" => 0, "report_ids" => [], "incomplete_report_ids" => [],
          "holding_row_count" => 0, "position_count" => 0, "known_value_usd" => nil, "total_value_usd" => nil
        }
        metadata.merge("period_of_report" => (side == "current" ? @period : @prior),
          "source_scope" => metadata.fetch("report_count").positive? ? "effective_holdings" : "observed_reports",
          "sources" => (row ? row.fetch("#{side}_source_ids") : []).map { |id| FilingProvenance.render(sources.fetch(id).filing, as_of: @as_of) })
      end

      def sql
        connection = ApplicationRecord.connection
        current, prior = [ @period, @prior ].map { |period| connection.quote(period) }
        scope = { institutional_filer_id: @fund.id, period_of_report: [ @period, @prior ] }
        reports = InstitutionalReportScope.new(as_of: @as_of, max_report_id: @bounds.fetch("reports"),
          max_filing_id: @bounds.fetch("filings"), report_ids: InstitutionalReport.where(scope).select(:id))
        visible, effective = reports.visible_reports, reports.effective_reports
        portfolios = FundPortfolioSql.new(visible:, effective:, periods: "SELECT period_of_report FROM (VALUES (#{current}::date), (#{prior}::date)) requested(period_of_report)",
          max_holding_id: @bounds.fetch("holdings"))
        <<~SQL
          WITH #{portfolios.ctes}, deltas AS (
            SELECT c.value_usd AS current_value, p.value_usd AS prior_value
            FROM (SELECT * FROM positions WHERE period_of_report = #{current}) c
            FULL OUTER JOIN (SELECT * FROM positions WHERE period_of_report = #{prior}) p
              ON p.cusip = c.cusip AND p.put_call IS NOT DISTINCT FROM c.put_call AND p.share_type = c.share_type
          ), inputs AS (
            SELECT #{FundPortfolioSql.metadata_json('c')} AS current_portfolio,
              #{FundPortfolioSql.metadata_json('p')} AS prior_portfolio,
              CASE WHEN c.report_count > 0 THEN c.report_ids ELSE ARRAY(
                SELECT id FROM visible WHERE period_of_report = #{current} ORDER BY known_filed_at DESC, known_accession DESC
              ) END AS current_source_ids,
              CASE WHEN p.report_count > 0 THEN p.report_ids ELSE ARRAY(
                SELECT id FROM visible WHERE period_of_report = #{prior} ORDER BY known_filed_at DESC, known_accession DESC
              ) END AS prior_source_ids,
              CASE
                WHEN NOT EXISTS (SELECT 1 FROM visible WHERE period_of_report = #{current}) THEN 'no_current_report'
                WHEN #{current}::date > #{connection.quote(@as_of.to_date)}::date THEN 'future_report_period'
                WHEN NOT EXISTS (SELECT 1 FROM visible WHERE period_of_report = #{prior}) THEN 'no_prior_report'
                WHEN c.report_count = 0 THEN 'no_effective_current_holdings'
                WHEN p.report_count = 0 THEN 'no_effective_prior_holdings'
                WHEN NOT c.complete THEN 'incomplete_current_portfolio'
                WHEN NOT p.complete THEN 'incomplete_prior_portfolio'
                WHEN c.total_value_usd = 0 THEN 'zero_current_portfolio_value'
                WHEN p.total_value_usd = 0 THEN 'zero_prior_portfolio_value'
              END AS unavailable_reason,
              CASE WHEN c.complete AND p.complete AND c.total_value_usd > 0 AND p.total_value_usd > 0
                AND #{current}::date <= #{connection.quote(@as_of.to_date)}::date THEN (
                SELECT SUM(ABS(COALESCE(d.current_value, 0) * p.total_value_usd - COALESCE(d.prior_value, 0) * c.total_value_usd))
                  * 50 / (c.total_value_usd * p.total_value_usd) FROM deltas d
              ) END AS turnover_percent
            FROM portfolios c CROSS JOIN portfolios p
            WHERE c.period_of_report = #{current} AND p.period_of_report = #{prior}
          ) SELECT inputs.*, (SELECT id FROM visible WHERE id = ANY(current_source_ids || prior_source_ids)
            ORDER BY known_filed_at DESC, known_accession DESC LIMIT 1) AS primary_report_id FROM inputs
        SQL
      end
    end
  end
end
