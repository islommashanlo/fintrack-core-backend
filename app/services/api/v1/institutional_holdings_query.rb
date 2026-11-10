# frozen_string_literal: true

module Api
  module V1
    class InstitutionalHoldingsQuery
      BOUNDS = { "filings" => Filing, "reports" => InstitutionalReport, "holdings" => InstitutionalHolding }.freeze
      SORTS = {
        "value_usd" => "institutional_holdings.value_usd", "shares" => "institutional_holdings.shares",
        "cusip" => "institutional_holdings.cusip", "row_sequence" => "institutional_holdings.row_seq"
      }.freeze

      def self.validate_filters!(values)
        %w[cusip put_call share_type].each do |key|
          next unless values[key]

          valid = case key
          when "cusip" then values[key].match?(/\A[0-9A-Z]{9}\z/)
          when "put_call" then %w[PUT CALL].include?(values[key])
          when "share_type" then %w[SH PRN].include?(values[key])
          end
          raise InvalidParameter, "Invalid #{key} parameter" unless valid
        end
      end

      attr_reader :reports

      def initialize(page:, filters:)
        @page = page
        @filters = filters
        @reports = InstitutionalReportScope.new(as_of: page.as_of, max_report_id: page.bound("reports"),
                                                max_filing_id: page.bound("filings"), max_holding_id: page.bound("holdings"))
      end

      def for_fund(fund, period: nil)
        period ||= @reports.visible_reports.where(institutional_filer_id: fund.id).except(:select).maximum(:period_of_report)
        filter(@reports.holdings.where(institutional_report_id: @reports.effective_reports
          .where(institutional_filer_id: fund.id, period_of_report: period).select(:id)))
      end

      def for_company(ticker, period: nil)
        selected = @reports.effective_reports
        if period
          selected = selected.where(period_of_report: period)
        else
          selected = selected.where(<<~SQL.squish)
            institutional_reports.period_of_report = (
              SELECT MAX(visible.period_of_report) FROM (#{@reports.visible_reports.to_sql}) visible
              WHERE visible.institutional_filer_id = institutional_reports.institutional_filer_id
            )
          SQL
        end
        mappings = CusipSecurityMapping.joins(:security).where(status: "mapped")
          .where("UPPER(securities.ticker) = ? AND cusip_security_mappings.id <= ? AND first_seen_at <= ?",
                 ticker, @page.bound("mappings"), @page.as_of)
        filter(@reports.holdings.where(institutional_report_id: selected.select(:id), cusip: mappings.select(:cusip)))
      end

      private

      def filter(scope)
        %w[cusip put_call share_type].each { |key| scope = scope.where(key => @filters[key]) if @filters[key] }
        scope
      end
    end
  end
end
