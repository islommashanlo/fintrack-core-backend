# frozen_string_literal: true

module Api
  module V1
    # Calculate the full effective portfolio before filtering or paging its rows.
    class FundPortfolioQuery
      Result = Data.define(:meta, :positions)

      def initialize(page:, reports:, fund:, period:)
        @page, @reports, @fund, @period = page, reports, fund, period
      end

      def call(holdings)
        ids = holdings.map(&:id)
        aggregate(<<~SQL)
          SELECT COALESCE(jsonb_object_agg(h.id::text, #{position_json('p')}), '{}'::jsonb)
          FROM lines h INNER JOIN ranked p ON p.cusip = h.cusip AND p.put_call IS NOT DISTINCT FROM h.put_call
            AND p.share_type = h.share_type
          WHERE h.id IN (#{ids.empty? ? 'NULL' : ids.join(',')})
        SQL
      end

      # Project only the page's keys while ranking the entire portfolio in SQL.
      def for_positions(changes)
        keys = changes.map do |change|
          [ change.id.to_s, change.cusip, change.put_call, change.share_type ]
            .map { |value| "#{ApplicationRecord.connection.quote(value)}::text" }.join(", ")
        end
        requested = if keys.empty?
          "SELECT NULL::text, NULL::text, NULL::text, NULL::text WHERE FALSE"
        else
          "VALUES #{keys.map { |key| "(#{key})" }.join(', ')}"
        end
        aggregate(<<~SQL)
          SELECT COALESCE(jsonb_object_agg(k.id, #{position_json('p')}), '{}'::jsonb)
          FROM (#{requested}) AS k(id, cusip, put_call, share_type)
          INNER JOIN ranked p ON p.cusip = k.cusip AND p.put_call IS NOT DISTINCT FROM k.put_call
            AND p.share_type = k.share_type
        SQL
      end

      private

      def position_json(name)
        "jsonb_build_object('row_count', #{name}.row_count, 'value_usd', #{name}.value_usd::text, " \
          "'weight_percent', #{name}.weight_percent::text, 'rank', #{name}.position_rank)"
      end

      def aggregate(projection)
        visible = @reports.visible_reports.where(institutional_filer_id: @fund.id, period_of_report: @period)
        effective = @reports.effective_reports.where(institutional_filer_id: @fund.id, period_of_report: @period)
        periods = ApplicationRecord.sanitize_sql([ "SELECT ?::date AS period_of_report", @period ])
        sql = FundPortfolioSql.new(visible:, effective:, periods:, max_holding_id: @page.bound("holdings"))
        row = CursorPage.sql_rows(<<~SQL).first
          WITH #{sql.ctes}
          SELECT c.*, (#{projection}) AS positions FROM portfolios c
        SQL
        Result.new(meta: row.except("positions", "period_of_report"), positions: row.fetch("positions"))
      end
    end
  end
end
