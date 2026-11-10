# frozen_string_literal: true

module ActivityScoring
  # Pure aggregation. Unknown inputs remain unknown and never earn zero points.
  class Calculator
    def initialize(definition:)
      @definition = definition
      @score = definition.fetch("score")
      @proposal = @score.fetch("proposal")
      @factors = @proposal.fetch("factors")
      ids = @factors.map { |factor| factor.fetch("id") }
      unless ids.uniq == ids && @factors.sum { |factor| factor.fetch("proposed_weight") } == @proposal.fetch("positive_weight_total")
        raise ArgumentError, "Invalid factor weights"
      end
    end

    def call(factors:, lateness:, eligibility_reason: nil)
      raise ArgumentError, "Unknown factors" unless (factors.keys - @factors.map { |factor| factor.fetch("id") }).empty?

      breakdown = @factors.map do |factor|
        measure(factor.fetch("id"), factor.fetch("proposed_weight"), factors.fetch(factor.fetch("id")))
      end
      penalty = measure("lateness", @proposal.fetch("maximum_lateness_penalty"), lateness, negative: true)
      missing = (breakdown + [ penalty ]).reject { |factor| factor[:status] == "available" }.map { |factor| factor[:id] }
      status = if eligibility_reason then "ineligible"
      elsif missing.any? then "incomplete"
      elsif @score.fetch("status") != "available" then "draft"
      else "available"
      end
      total = if status == "available"
        points = breakdown.sum { |factor| factor.fetch(:points) } + penalty.fetch(:points)
        points.round(0).to_i.clamp(@score.fetch("minimum"), @score.fetch("maximum"))
      end
      level = @score.fetch("levels").find { |entry| total.between?(entry.fetch("minimum"), entry.fetch("maximum")) } if total
      {
        status:, eligibility_reason:, methodology_version: @definition.fetch("version"), score: total, level: level&.fetch("id"),
        reasons: status == "available" ? (breakdown + [ penalty ]).sort_by { |factor| -factor[:points].abs }.first(4).pluck(:reason) : [],
        coverage: {
          available_weight: breakdown.select { |factor| factor[:status] == "available" }.sum { |factor| factor[:weight] },
          required_weight: @proposal.fetch("positive_weight_total"), missing_factors: missing,
          lateness_available: penalty[:status] == "available"
        }, factors: breakdown + [ penalty ]
      }
    end

    private

    def measure(id, weight, input, negative: false)
      status = input.fetch(:status)
      raise ArgumentError, "Invalid factor status" unless %w[available unavailable].include?(status)

      if status == "available"
        value = BigDecimal(input.fetch(:value).to_s)
        raise ArgumentError, "Invalid factor value" unless value.finite? && value.between?(0, 1)
        points = value * weight * (negative ? -1 : 1)
      elsif input[:value]
        raise ArgumentError, "Unavailable factor has a value"
      end
      { id:, status:, weight:, value:, points:, reason: input.fetch(:reason),
        unavailable_reason: input[:unavailable_reason], inputs: input.fetch(:inputs) }
    end
  end
end
