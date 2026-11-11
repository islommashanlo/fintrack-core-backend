# frozen_string_literal: true

class NewsAlertConditions
  FIELDS = %w[kinds source providers].freeze
  class Invalid < TransactionAlertConditions::Invalid; end

  def self.normalize(value)
    raise Invalid unless value.is_a?(Hash) && (value.keys - FIELDS).empty?
    result = value.deep_dup
    if result.key?("kinds")
      kinds = result["kinds"]
      raise Invalid unless kinds.is_a?(Array) && kinds.size.between?(1, 3) && kinds.all? { |kind| NewsItem::KINDS.include?(kind) }
      result["kinds"] = kinds.uniq.sort
    end
    if result.key?("providers")
      keys = result["providers"]
      raise Invalid unless keys.is_a?(Array) && keys.size.between?(1, 10) && keys.all? { |key| key.is_a?(String) && key.match?(/\A[a-z][a-z0-9_]{0,39}\z/) }
      result["providers"] = keys.uniq.sort
    end
    if result.key?("source")
      source = result["source"]
      raise Invalid unless source.is_a?(String) && source.present? && source.length <= 200 && !source.match?(/[<>[:cntrl:]]/)
    end
    result
  end
end
