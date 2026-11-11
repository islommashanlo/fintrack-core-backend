# frozen_string_literal: true

module MarketData
  module Publication
    module_function

    # Storing a vendor's bars does not authorize public redistribution.
    def providers
      ENV.fetch("MARKET_DATA_PUBLIC_PROVIDERS", "").split(",").map(&:strip).reject(&:empty?).uniq.sort
        .select { |key| key.match?(/\A[a-z][a-z0-9_]{0,39}\z/) }
    end
  end
end
