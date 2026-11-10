# frozen_string_literal: true

module Api
  module V1
    class FilingProvenance
      def self.render(filing, as_of: Time.current)
        {
          accession: filing.accession_no, sec_url: filing.sec_url, form_type: filing.form_type,
          filed_at: filing.filed_at, accepted_at: filing.accepted_at, ingested_at: filing.ingested_at,
          data_age_days: filing.data_age_days(as_of:)
        }
      end
    end
  end
end
