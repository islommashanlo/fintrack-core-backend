# frozen_string_literal: true

module Api
  module V1
    class CompanySerializer
      def self.render(company, as_of: Time.current)
        {
          cik: company.issuer_cik, ticker: company.ticker, name: company.name,
          latest_filing: company.filing && FilingProvenance.render(company.filing, as_of:),
          insider_summary: company.summary, insider_summaries: company.summaries
        }
      end
    end
  end
end
