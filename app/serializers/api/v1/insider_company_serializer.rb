# frozen_string_literal: true

module Api
  module V1
    class InsiderCompanySerializer
      def self.render(filing, as_of: Time.current)
        FilingProvenance.render(filing, as_of:).merge(
          cik: filing.issuer_cik, name: filing.issuer_name, ticker: filing.issuer_ticker,
          role: {
            is_director: filing["is_director"], is_officer: filing["is_officer"],
            is_ten_percent_owner: filing["is_ten_percent_owner"], is_other: filing["is_other"],
            officer_title: filing["officer_title"]
          }
        )
      end
    end
  end
end
