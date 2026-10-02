# frozen_string_literal: true

# Converts a reported 13F value into dollars without changing the reported value.
# Unit detection is deliberately supplied by the caller until the empirical cutoff is
# resolved; this class has no date-based assumption hidden inside it.
class Form13fValueNormalizer
  Result = Data.define(:value_reported, :value_unit, :value_usd, :suspect, :suspect_reason)

  UNIT_MULTIPLIERS = {
    "whole_dollars" => BigDecimal("1"),
    "thousands" => BigDecimal("1000")
  }.freeze

  UNIT_ALIASES = {
    "dollars" => "whole_dollars",
    "whole-dollar" => "whole_dollars",
    "whole dollars" => "whole_dollars",
    "thousand" => "thousands"
  }.freeze

  def self.normalize(value_reported:, value_unit:)
    new(value_reported:, value_unit:).normalize
  end

  def initialize(value_reported:, value_unit:)
    @value_reported = value_reported
    @value_unit = value_unit
  end

  def normalize
    reported = decimal(@value_reported)
    unit = canonical_unit(@value_unit)
    multiplier = UNIT_MULTIPLIERS[unit]

    return Result.new(
      value_reported: reported,
      value_unit: unit,
      value_usd: nil,
      suspect: true,
      suspect_reason: "unknown_value_unit"
    ) unless multiplier

    Result.new(
      value_reported: reported,
      value_unit: unit,
      value_usd: reported * multiplier,
      suspect: false,
      suspect_reason: nil
    )
  end

  private

  def decimal(value)
    return value if value.is_a?(BigDecimal)

    BigDecimal(value.to_s)
  rescue ArgumentError
    raise ArgumentError, "value_reported is not numeric: #{value.inspect}"
  end

  def canonical_unit(value)
    normalized = value.to_s.strip.downcase
    UNIT_ALIASES.fetch(normalized, normalized)
  end
end
