# frozen_string_literal: true

module Api
  module V1
    class FundSerializer
      def self.render(fund, as_of: Time.current)
        { cik: fund.cik, name: fund.name }
      end
    end
  end
end
