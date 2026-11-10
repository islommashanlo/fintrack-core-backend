# frozen_string_literal: true

module Api
  module V1
    class FilingSummarySerializer
      def self.render(filing, as_of: Time.current)
        FilingProvenance.render(filing, as_of:).merge(
          period_of_report: filing.period_of_report, issuer_cik: filing.issuer_cik,
          issuer_name: filing.issuer_name, issuer_ticker: filing.issuer_ticker,
          is_amendment: filing.amendment?, amends_accession: filing.amends_accession_no,
          superseded_by: filing.superseded_by_accession_no
        )
      end
    end
  end
end
