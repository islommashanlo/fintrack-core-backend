# frozen_string_literal: true

require "uri"

module Api
  module V1
    class CompanyHistorySerializer
      def initialize(rows:, ticker:, as_of:, filters:)
        @ticker, @as_of = ticker, as_of
        @filters = filters.slice("cusip", "put_call", "share_type")
        @positions = rows.to_h { |row| [ row.id, parse_positions(row) ] }
        ids = rows.flat_map { |row| Array(row["report_ids"]) + prior_ids(row) } +
          @positions.values.flatten.map { |position| position.fetch("primary_report_id") }
        @reports = InstitutionalReport.where(id: ids).includes(:filing, :institutional_filer).index_by(&:id)
      end

      def render(row)
        period = row.period_of_report
        FilingProvenance.render(@reports.fetch(row["primary_report_id"]).filing, as_of: @as_of).merge(
          ticker: @ticker, period_of_report: period, prior_period_of_report: row["prior_period"],
          holder_count_delta: row["holder_count_delta"],
          **row.attributes.slice("expected_fund_count", "reporting_fund_count", "missing_fund_count", "notice_fund_count",
            "suspect_report_fund_count", "excluded_holding_rows", "complete", "observed_holder_count", "holder_count",
            "holding_row_count", "suspect", "source_count", "position_count"),
          positions: @positions.fetch(row.id).map do |position|
            filing = @reports.fetch(position.fetch("primary_report_id")).filing
            FilingProvenance.render(filing, as_of: @as_of).merge(position.except("primary_report_id"),
              detail_path: detail_path(period, position))
          end,
          sources: sources(Array(row["report_ids"])), prior_sources: sources(prior_ids(row)),
          prior_source_count: row["holder_count_delta"].nil? ? 0 : row["prior_source_count"],
          prior_sources_truncated: !row["holder_count_delta"].nil? && row["prior_source_count"] > CompanyHistorySql::SOURCE_LIMIT,
          sources_truncated: row["source_count"] > CompanyHistorySql::SOURCE_LIMIT,
          positions_truncated: row["position_count"] > CompanyHistorySql::POSITION_LIMIT,
          detail_path: detail_path(period)
        )
      end

      private

      def prior_ids(row)
        row["holder_count_delta"].nil? ? [] : Array(row["prior_report_ids"])
      end

      def sources(ids)
        ids.map do |id|
          report = @reports.fetch(id)
          FilingProvenance.render(report.filing, as_of: @as_of).merge(cik: report.institutional_filer.cik,
            fund_name: report.institutional_filer.name, period_of_report: report.period_of_report,
            report_type: report.report_type, amendment_type: report.amendment_type)
        end
      end

      def parse_positions(row)
        positions = row["positions"]
        positions.is_a?(String) ? JSON.parse(positions) : positions
      end

      def detail_path(period, position = nil)
        values = { period: period.iso8601 }.merge(@filters)
        values.merge!(position.slice("cusip", "put_call", "share_type").compact) if position
        "#{Rails.application.routes.url_helpers.institutional_api_v1_company_path(@ticker)}?#{URI.encode_www_form(values)}"
      end
    end
  end
end
