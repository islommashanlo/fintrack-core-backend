# frozen_string_literal: true

module FilingExplanations
  # Adapters select existing fact IDs; they never supply publishable prose.
  # A future external adapter must translate its transport errors to Unavailable.
  module Provider
    Result = Data.define(:model, :fact_ids)
    class Unavailable < StandardError; end
  end
end
