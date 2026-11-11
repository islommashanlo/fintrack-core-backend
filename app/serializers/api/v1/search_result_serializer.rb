# frozen_string_literal: true

module Api
  module V1
    class SearchResultSerializer
      def initialize(rows:, as_of:)
        @as_of = as_of
        @filings = Filing.where(id: rows.filter_map { |row| row["primary_filing_id"] }).index_by(&:id)
      end

      def render(row)
        filing = @filings[row["primary_filing_id"]]
        provenance = filing ? FilingProvenance.render(filing, as_of: @as_of) : {
          accession: nil, sec_url: nil, form_type: nil, filed_at: nil, accepted_at: nil, ingested_at: nil, data_age_days: nil
        }
        provenance.merge(row.slice("entity_type", "entity_key", "name", "ticker", "cik", "match_type"),
          profile_path: profile_path(row))
      end

      private

      def profile_path(row)
        routes = Rails.application.routes.url_helpers
        key = row.fetch("entity_key")
        case row.fetch("entity_type")
        when "issuer" then routes.api_v1_company_path(key)
        when "fund" then routes.api_v1_fund_path(key)
        when "person" then routes.api_v1_insider_path(key)
        end
      end
    end
  end
end
