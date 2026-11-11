# frozen_string_literal: true

class SavedScreenDefinition
  KEYS = %w[entity filters sort window_days].freeze

  def self.normalize(value)
    unless value.is_a?(Hash) && (value.keys - KEYS).empty?
      raise Api::V1::InvalidParameter, "Invalid saved screen definition"
    end

    result = Api::V1::ScreenerParameters.normalize(value).slice(*KEYS)
    result["window_days"] = result.fetch("window_days").to_i if result.key?("window_days")
    result
  end
end
