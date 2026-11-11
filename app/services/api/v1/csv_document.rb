# frozen_string_literal: true

module Api
  module V1
    class CsvDocument
      MAX_BYTES = 10.megabytes
      PROVENANCE = %w[accession form_type sec_url filed_at accepted_at ingested_at period_of_report data_age_days].freeze
      COLUMNS = {
        "insider-transactions" => %w[id insider_cik insider_name issuer.cik issuer.name issuer.ticker
          role.is_director role.is_officer role.is_ten_percent_owner role.is_other role.officer_title
          owner_sequence security_table transaction_sequence security_title transaction_date transaction_code
          activity_type direction shares price price_suspect price_suspect_reason value shares_owned_following
          acquired_disposed direct_or_indirect] + PROVENANCE,
        "fund-holdings" => %w[id fund.cik fund.name row_sequence cusip figi issuer_name title_of_class
          value_reported value_unit value_usd shares share_type put_call investment_discretion other_manager
          voting_authority.sole voting_authority.shared voting_authority.none suspect suspect_reason] + PROVENANCE,
        "fund-changes" => %w[fund.cik fund.name prior_period_of_report cusip put_call share_type issuer_name title_of_class
          change_type shares_before shares_after shares_delta value_usd_before value_usd_after value_usd_delta
          current_suspect prior_suspect current_sources prior_sources] + PROVENANCE
      }.transform_values { |columns| (columns + %w[disclaimer]).freeze }.freeze
      class TooLarge < StandardError; end

      def self.render(dataset:, rows:)
        columns = COLUMNS.fetch(dataset)
        body = +line(columns)
        rows.each do |row|
          cells = columns.map do |column|
            column == "disclaimer" ? FilingsIntel::DISCLAIMER : row.dig(*column.split(".").map(&:to_sym))
          end
          body << line(cells)
          raise TooLarge if body.bytesize > MAX_BYTES
        end
        body
      end

      def self.line(values)
        values.map { |value| '"' + cell(value).gsub('"', '""') + '"' }.join(",") + "\r\n"
      end
      private_class_method :line

      def self.cell(value)
        case value
        when nil then ""
        when BigDecimal then value.to_s("F")
        when Time, DateTime then value.iso8601(6)
        when Date then value.iso8601
        when Array, Hash then value.to_json
        when String
          # Quoting alone does not prevent spreadsheet formula evaluation.
          value.match?(/\A[\p{Space}\p{Cf}\p{Cc}]*[=+\-@]|\A[\t\r\n]/) ? "'#{value}" : value
        else value.to_s
        end
      end
      private_class_method :cell
    end
  end
end
