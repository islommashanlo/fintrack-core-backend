# frozen_string_literal: true

class ClusterAlertConditions
  FIELDS = %w[direction min_insiders min_value].freeze
  class Invalid < TransactionAlertConditions::Invalid; end

  def self.normalize(value)
    raise Invalid unless value.is_a?(Hash) && (value.keys - FIELDS).empty?
    result = value.deep_dup
    if result.key?("direction") && !%w[purchase sale].include?(result["direction"])
      raise Invalid
    end
    if result.key?("min_insiders")
      count = result["min_insiders"]
      raise Invalid unless count.is_a?(Integer) && count.between?(ActivityMethodology.minimum_insiders, 1000)
    end
    result.merge(TransactionAlertConditions.normalize(result.slice("min_value")))
  end
end
