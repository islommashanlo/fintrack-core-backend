# frozen_string_literal: true

# Decides whether a reported per-share price can be trusted in value calculations.
# It only ever produces a flag (invariant 3): the reported price is stored untouched.
module PriceCheck
  # Filers sometimes put the total value of the trade in the per-share field. A real
  # per-share price above this is rare enough (Berkshire Hathaway Class A is the known
  # exception) that such rows are held out of value sums until someone looks at them.
  MAX_PLAUSIBLE_PRICE = 50_000

  module_function

  # Returns a short reason when the price is suspect, or nil when it is usable or absent.
  def suspect_reason(price:, transaction_code:)
    return nil if price.nil?
    return "negative" if price.negative?
    return "over_50k_per_share" if price > MAX_PLAUSIBLE_PRICE
    return "zero_on_open_market_code" if price.zero? && InsiderTransaction::OPEN_MARKET_CODES.include?(transaction_code)

    nil
  end
end
