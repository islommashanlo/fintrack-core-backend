# frozen_string_literal: true

module ActivityScoring
  class InstitutionalAssessment
    def initialize(row:, bounds:)
      @row = row
      @bounds = bounds
      @definition = ActivityMethodology.definition
      @rules = @definition.fetch("score").fetch("institutional_factors")
      data = row.fetch("position_data")
      @position = data.is_a?(String) ? JSON.parse(data) : data
    end

    def call
      @inputs = InstitutionalInputsQuery.new(row: @row, bounds: @bounds, rules: @rules).call
      coverage = source_coverage
      reason = "incomplete_report_context" unless @inputs.fetch("event_eligible") && coverage[:reports_complete]
      factors = @definition.fetch("score").fetch("proposal").fetch("factors").to_h do |factor|
        inputs = factor.fetch("id") == "issuer_scale_and_liquidity" ? { "requirements" => @definition.fetch("score").fetch("market_input_requirements") } : {}
        [ factor.fetch("id"), unavailable(reason || "market_inputs_unavailable", inputs:) ]
      end
      unless reason
        factors.merge!("own_history" => own_history, "reported_context" => reported_context,
          "position_size_change" => position_size_change, "corroborating_activity" => corroborating_activity)
      end
      Calculator.new(definition: @definition).call(factors:, lateness: reason ? unavailable(reason) : lateness,
        eligibility_reason: reason).merge(evaluated_at: @row.fetch("occurred_at"), source_coverage: coverage)
    end

    private

    def source_coverage
      ids = @inputs.fetch("checked_report_ids")
      invalid = @inputs.fetch("invalid_report_ids")
      missing = @row.fetch("context_report_ids") - ids
      value_incomplete = @inputs.fetch("value_incomplete_report_ids")
      { report_ids: ids, invalid_report_ids: invalid, missing_report_ids: missing, value_incomplete_report_ids: value_incomplete,
        reports_complete: missing.empty? && invalid.empty? && ids.any?,
        values_complete: missing.empty? && value_incomplete.empty? && invalid.empty? && ids.any? }
    end

    def own_history
      inputs = @inputs.slice("history_count", "history_less_or_equal_count", "history_first_at", "history_last_at")
        .merge("history_quarters" => @rules.fetch("history_quarters"), "minimum_history" => @rules.fetch("minimum_history"))
      return unavailable("unusable_reported_value_change", inputs:) if @row["value"].nil? || !source_coverage[:values_complete]
      return unavailable("insufficient_history", inputs:) if inputs.fetch("history_count") < @rules.fetch("minimum_history")

      value = BigDecimal(inputs.fetch("history_less_or_equal_count").to_s) / inputs.fetch("history_count")
      available(value, "Absolute reported value change is at or above #{inputs.fetch('history_less_or_equal_count')} of #{inputs.fetch('history_count')} observed prior same-direction position value changes.", inputs:)
    end

    def reported_context
      change = @position.fetch("change_type")
      available(@rules.fetch("change_type_values").fetch(change), "The reported position change is classified as #{change}.",
        inputs: { "change_type" => change })
    end

    def position_size_change
      prior = decimal("shares_before")
      after = decimal("shares_after")
      delta = decimal("shares_delta")
      inputs = { "shares_before" => prior, "shares_after" => after, "shares_delta" => delta }
      value = if @position.fetch("change_type") == "new"
        1 if prior.nil? && after&.positive? && delta == after
      elsif prior&.positive? && delta && (after || 0) - prior == delta
        [ delta.abs / prior, BigDecimal("1") ].min
      end
      return unavailable("invalid_position_baseline", inputs:) unless value

      available(value, "The reported share change is measured against the complete adjacent-quarter position baseline.", inputs:)
    end

    def corroborating_activity
      count = @inputs.fetch("participant_count")
      minimum = @rules.fetch("participation_full_count")
      value = (BigDecimal((count - 1).to_s) / (minimum - 1)).clamp(0, 1)
      available(value, "#{count} distinct reporting funds disclosed the same position change type for this security and quarter by the evaluation time.",
        inputs: { "participant_count" => count, "full_count" => minimum, "cusip" => @row.fetch("cusip"),
                  "put_call" => @row["put_call"], "share_type" => @row.fetch("share_type"), "period_of_report" => @row.fetch("period_of_report") })
    end

    def lateness
      period = @row.fetch("period_of_report")
      date = @row.fetch("occurred_at").in_time_zone("America/New_York").to_date
      inputs = { "period_of_report" => period, "filing_date" => date }
      return unavailable("future_report_period", inputs:) if period > date

      days = (date - period).to_i
      value = [ BigDecimal(days.to_s) / @rules.fetch("staleness_full_penalty_days"), BigDecimal("1") ].min
      available(value, "The comparison was available #{days} calendar days after the reported quarter end.", inputs: inputs.merge("calendar_days" => days))
    end

    def decimal(key)
      value = @position[key]
      BigDecimal(value.to_s) if value
    end

    def available(value, reason, inputs:)
      { status: "available", value:, reason:, inputs: }
    end

    def unavailable(reason, inputs: {})
      { status: "unavailable", unavailable_reason: reason, reason: "Input unavailable: #{reason.tr('_', ' ')}.", inputs: }
    end
  end
end
