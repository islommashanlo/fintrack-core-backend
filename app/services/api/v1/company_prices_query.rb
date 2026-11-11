# frozen_string_literal: true

module Api
  module V1
    class CompanyPricesQuery
      PARAMETERS = %w[range series_id sort limit cursor].freeze
      RANGES = { "1m" => 1, "3m" => 3, "6m" => 6, "1y" => 12 }.freeze
      MARKER_LIMIT = 20

      def initialize(company:, parameters:, as_of: Time.current)
        @company, @parameters, @resolution_time = company, parameters, as_of
        @range = parameters.fetch("range", "3m")
        raise InvalidParameter, "Invalid range parameter" unless RANGES.key?(@range)
        if parameters["series_id"] && !parameters["series_id"].match?(/\A[1-9][0-9]{0,17}\z/)
          raise InvalidParameter, "Invalid series_id parameter"
        end
        @providers = MarketData::Publication.providers
        resolve_series
        @page = CursorPage.new(parameters:, context: {
          "resource" => "company_prices", "ticker" => company.ticker, "issuer_cik" => company.issuer_cik,
          "series_id" => @series&.id, "status" => @status, "public_providers" => @providers
        }, sorts: { "date" => "prices_daily.session_date" }, default_sort: "date",
          bounds: { "prices" => PriceDaily, "filings" => Filing }, as_of:)
        @to = @page.as_of.utc.to_date
        @from = (@to << RANGES.fetch(@range)) + 1
      end

      def call
        result = @page.call(price_scope)
        markers = marker_scope
        marker_count = markers.count
        marker_rows = markers.order(filed_at: :desc, accession_no: :desc).limit(MARKER_LIMIT)
        {
          data: {
            series: @series && CompanyPriceSerializer.series(@series),
            bars: result.records.map { |row| CompanyPriceSerializer.bar(row) },
            filing_markers: marker_rows.map { |filing| CompanyPriceSerializer.marker(filing, as_of: @page.as_of) }
          },
          meta: result.meta.merge(status: @status, range: @range, from: @from, to: @to,
            coverage: { stored_bar_count: result.meta.fetch(:total_count), complete: nil,
                        calendar_available: false, missing_sessions: nil, prices_fetched: false,
                        mapping_policy: "current_local_cache", issuer_security_link_verified: false },
            filing_markers: { total_count: marker_count, shown: [ marker_count, MARKER_LIMIT ].min,
                              truncated: marker_count > MARKER_LIMIT, limit: MARKER_LIMIT, date_basis: "filed_at_utc",
                              supported_forms: Filing::FORM4_TYPES },
            disclaimer: FilingsIntel::DISCLAIMER)
        }
      end

      private

      def resolve_series
        @status = "redistribution_disabled"
        return if @providers.empty?

        securities = Security.where("UPPER(ticker) = ?", @company.ticker)
          .where(id: CusipSecurityMapping.where(status: "mapped").where("first_seen_at <= ?", @resolution_time).select(:security_id))
        series = PriceSeries.where(security_id: securities.select(:id), provider: @providers)
          .where("created_at <= ?", @resolution_time).includes(:security)
        if @parameters["series_id"]
          @series = series.find(@parameters.fetch("series_id"))
        else
          security_ids = securities.limit(2).pluck(:id)
          @status = security_ids.empty? ? "security_unmapped" : "security_ambiguous"
          return unless security_ids.one?

          candidates = series.limit(2).to_a
          @status = candidates.empty? ? "series_unavailable" : "series_ambiguous"
          return unless candidates.one?

          @series = candidates.first
        end
        @status = "available"
      end

      def price_scope
        return PriceDaily.none unless @series

        @series.prices_daily.where(session_date: @from..@to)
          .where("observed_at <= ? AND id <= ?", @page.as_of, @page.bound("prices"))
      end

      def marker_scope
        return Filing.none unless @company.issuer_cik

        Filing.form4.parsed.where(issuer_cik: @company.issuer_cik)
          .where("UPPER(issuer_ticker) = ?", @company.ticker)
          .where("filed_at >= ? AND filed_at <= ? AND ingested_at <= ? AND (parsed_at IS NULL OR parsed_at <= ?) AND id <= ?",
                 Time.utc(@from.year, @from.month, @from.day), @page.as_of, @page.as_of, @page.as_of, @page.bound("filings"))
      end
    end
  end
end
