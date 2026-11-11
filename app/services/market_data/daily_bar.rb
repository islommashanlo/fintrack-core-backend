# frozen_string_literal: true

module MarketData
  # Exact decimals only: adapters must not pass binary floating-point prices.
  DailyBar = Data.define(:session_date, :open, :high, :low, :close, :volume) do
    def initialize(session_date:, open:, high:, low:, close:, volume:)
      unless session_date.instance_of?(Date)
        raise Provider::InvalidResponse, "Session date must be a Date"
      end
      values = { open:, high:, low:, close:, volume: }.transform_values do |value|
        unless value.is_a?(BigDecimal) || value.is_a?(Integer) ||
               (value.is_a?(String) && value.match?(/\A\d+(?:\.\d+)?\z/))
          raise Provider::InvalidResponse, "OHLCV must use exact decimal values"
        end
        number = BigDecimal(value.to_s)
        raise Provider::InvalidResponse, "OHLCV must be finite" unless number.finite?

        number
      end
      unless values.values_at(:open, :high, :low, :close).all?(&:positive?) &&
             values[:high] >= [ values[:open], values[:close] ].max &&
             values[:low] <= [ values[:open], values[:close] ].min &&
             values[:volume] >= 0 && values[:volume].frac.zero?
        raise Provider::InvalidResponse, "Invalid OHLCV range or volume"
      end

      super(session_date:, **values)
    end
  end
end
