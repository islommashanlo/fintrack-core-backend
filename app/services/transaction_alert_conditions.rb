# frozen_string_literal: true

class TransactionAlertConditions
  ENUMS = {
    "direction" => %w[purchase sale other], "role" => %w[director officer ten_percent_owner other],
    "type" => %w[open_market administrative], "security_table" => InsiderTransaction::SECURITY_TABLES
  }.freeze
  class Invalid < StandardError; end

  def self.normalize(value)
    raise Invalid unless value.is_a?(Hash) && (value.keys - (ENUMS.keys + %w[codes min_value])).empty?
    result = value.deep_dup
    ENUMS.each { |key, allowed| raise Invalid if result.key?(key) && !allowed.include?(result[key]) }
    if result.key?("codes")
      codes = result["codes"]
      raise Invalid unless codes.is_a?(Array) && codes.length.between?(1, 26) &&
        codes.all? { |code| code.is_a?(String) && code.match?(/\A[A-Za-z]\z/) }
      result["codes"] = codes.map(&:upcase).uniq.sort
    end
    if result.key?("min_value")
      amount = result["min_value"]
      raise Invalid unless (amount.is_a?(String) || amount.is_a?(Integer)) && amount.to_s.match?(/\A\d{1,30}(?:\.\d{1,12})?\z/)
      result["min_value"] = BigDecimal(amount.to_s).to_s("F")
    end
    result
  end
end
