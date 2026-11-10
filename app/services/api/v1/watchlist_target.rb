# frozen_string_literal: true

module Api
  module V1
    class WatchlistTarget
      TYPES = { "issuer" => "Ticker", "fund" => "InstitutionalFiler", "person" => "Insider" }.freeze
      API_TYPES = TYPES.invert.freeze

      def self.resolve(type:, key:)
        raise InvalidParameter, "Invalid entity_type parameter" unless TYPES.key?(type)

        if type == "issuer"
          company = CompanyProfile.new(ticker: key)
          return FollowTarget::Target.new("Ticker", company.ticker, company.name.presence || company.ticker)
        end
        raise InvalidParameter, "Invalid entity_key parameter" unless key.match?(/\A\d{10}\z/)

        if type == "fund"
          fund = InstitutionalFiler.find_by!(cik: key)
          FollowTarget::Target.new("InstitutionalFiler", fund.cik, fund.name)
        else
          insider = InsiderProfile.new(cik: key)
          FollowTarget::Target.new("Insider", insider.cik, insider.name.presence || insider.cik)
        end
      end
    end
  end
end
