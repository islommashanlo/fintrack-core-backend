# frozen_string_literal: true

module Api
  module V1
    class InsiderProfileSerializer
      def self.render(insider, as_of: Time.current)
        {
          cik: insider.cik, name: insider.name,
          latest_filing: FilingProvenance.render(insider.latest_filing, as_of:),
          summaries: insider.summaries
        }
      end
    end
  end
end
