# frozen_string_literal: true

module MarketData
  # Implementations return finalized session bars in the requested series'
  # currency and adjustment basis. Transport/parsing belongs in the adapter.
  module Provider
    class NotConfigured < StandardError; end
    class Unavailable < StandardError; end
    class InvalidResponse < StandardError; end

    class Disabled
      def key
        "disabled"
      end

      def daily_bars(series:, from:, to:)
        raise NotConfigured, "No market-data provider is configured"
      end
    end
  end
end
