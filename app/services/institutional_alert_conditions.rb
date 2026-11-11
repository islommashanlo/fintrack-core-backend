# frozen_string_literal: true

class InstitutionalAlertConditions
  FIELDS = %w[change_types direction cusip put_call share_type min_value].freeze
  class Invalid < TransactionAlertConditions::Invalid; end

  def self.normalize(value)
    raise Invalid unless value.is_a?(Hash) && (value.keys - FIELDS).empty?
    result = value.deep_dup
    if result.key?("change_types")
      types = result["change_types"]
      raise Invalid unless types.is_a?(Array) && types.length.between?(1, 4) &&
        types.all? { |type| Api::V1::PositionChangeSerializer::CHANGE_TYPES.value?(type) }
      result["change_types"] = types.uniq.sort
    end
    raise Invalid if result.key?("direction") && !%w[increase decrease].include?(result["direction"])
    %w[cusip put_call share_type].each do |key|
      raise Invalid if result.key?(key) && !result[key].is_a?(String)
    end
    Api::V1::InstitutionalHoldingsQuery.validate_filters!(result.slice("cusip", "put_call", "share_type"))
    result.merge(TransactionAlertConditions.normalize(result.slice("min_value")))
  rescue Api::V1::InvalidParameter
    raise Invalid
  end
end
