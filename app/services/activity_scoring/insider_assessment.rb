# frozen_string_literal: true

module ActivityScoring
  class InsiderAssessment
    def initialize(transaction:, max_filing_id:, max_transaction_id:)
      @transaction = transaction
      @max_filing_id = max_filing_id
      @max_transaction_id = max_transaction_id
      @definition = ActivityMethodology.definition
      @rules = @definition.fetch("score").fetch("insider_factors")
    end

    def call
      reason = eligibility_reason
      unless reason
        @inputs = InsiderInputsQuery.new(transaction: @transaction, rules: @rules,
          max_filing_id: @max_filing_id, max_transaction_id: @max_transaction_id).call
        reason = "unresolved_event" unless @inputs.fetch("event_eligible")
      end
      factors = @definition.fetch("score").fetch("proposal").fetch("factors").to_h do |factor|
        [ factor.fetch("id"), unavailable(reason || "market_inputs_unavailable") ]
      end
      unless reason
        factors.merge!("own_history" => own_history, "reported_context" => reported_context,
          "position_size_change" => position_size_change, "corroborating_activity" => corroborating_activity)
      end
      Calculator.new(definition: @definition).call(factors:, lateness: reason ? unavailable(reason) : lateness,
        eligibility_reason: reason).merge(evaluated_at: @transaction.filing.filed_at)
    end

    private

    def eligibility_reason
      return "unsupported_transaction" unless @transaction.owner_seq == 1 && @transaction.security_table == "non_derivative" && @transaction.open_market?
      "unresolved_amendment" if @transaction.filing.unmatched_reason || (@transaction.filing.amendment? && @transaction.filing.amends_accession_no.nil?)
    end

    def own_history
      inputs = @inputs.slice("history_count", "history_less_or_equal_count", "history_first_at", "history_last_at")
        .merge("history_days" => @rules.fetch("history_days"), "minimum_history" => @rules.fetch("minimum_history"))
      return unavailable("unusable_reported_value", inputs:) unless usable_value?
      return unavailable("insufficient_history", inputs:) if inputs.fetch("history_count") < @rules.fetch("minimum_history")

      value = BigDecimal(inputs.fetch("history_less_or_equal_count").to_s) / inputs.fetch("history_count")
      available(value, "Reported value is at or above #{inputs.fetch('history_less_or_equal_count')} of #{inputs.fetch('history_count')} observed prior same-direction transaction values.", inputs:)
    end

    def reported_context
      roles = @rules.fetch("role_values")
      role = roles.keys.find { |key| @transaction.public_send("is_#{key}") } || "none"
      value = role == "none" ? 0 : roles.fetch(role)
      description = role == "none" ? "No officer, director, ten-percent-owner or other role is checked." : "The first-listed reporting owner is identified as #{role.tr('_', ' ')}."
      available(value, description, inputs: { "role" => role, "officer_title" => @transaction.officer_title })
    end

    def position_size_change
      shares = @transaction.shares
      post = @transaction.shares_owned_following
      inputs = { "shares" => shares, "shares_owned_following" => post, "acquired_disposed" => @transaction.acquired_disposed }
      return unavailable("missing_position", inputs:) if shares.nil? || post.nil?
      return unavailable("invalid_position", inputs:) unless shares.positive? && post >= 0
      expected = @transaction.transaction_code == "P" ? "A" : "D"
      return unavailable("inconsistent_direction", inputs:) unless @transaction.acquired_disposed == expected

      prior = expected == "A" ? post - shares : post + shares
      inputs["inferred_prior_shares"] = prior
      return unavailable("invalid_position", inputs:) if prior.negative?

      value = prior.zero? ? BigDecimal("1") : [ shares / prior, BigDecimal("1") ].min
      available(value, prior.zero? ? "The reported line implies a zero preceding holding." : "Reported shares changed by #{(shares / prior * 100).round(2).to_s('F')}% of the inferred preceding holding.", inputs:)
    end

    def corroborating_activity
      count = @inputs.fetch("participant_count")
      minimum = ActivityMethodology.minimum_insiders
      value = (BigDecimal((count - 1).to_s) / (minimum - 1)).clamp(0, 1)
      available(value, "#{count} distinct first-listed owners reported same-direction transactions for this issuer within #{ActivityMethodology.window_days} days.",
        inputs: { "participant_count" => count, "window_days" => ActivityMethodology.window_days, "cluster_minimum" => minimum })
    end

    def lateness
      date = @transaction.transaction_date
      filing_date = @transaction.filing.filed_at.in_time_zone("America/New_York").to_date
      inputs = { "transaction_date" => date, "filing_date" => filing_date }
      return unavailable("missing_transaction_date", inputs:) unless date
      return unavailable("future_transaction_date", inputs:) if date > filing_date

      days = (filing_date - date).to_i
      value = BigDecimal(days.to_s) / @rules.fetch("staleness_full_penalty_days")
      available([ value, BigDecimal("1") ].min, "SEC acceptance occurred #{days} calendar days after the reported transaction date.", inputs: inputs.merge("calendar_days" => days))
    end

    def usable_value?
      @transaction.shares&.positive? && @transaction.price&.positive? && !@transaction.price_suspect
    end

    def available(value, reason, inputs:)
      { status: "available", value:, reason:, inputs: }
    end

    def unavailable(reason, inputs: {})
      { status: "unavailable", unavailable_reason: reason, reason: "Input unavailable: #{reason.tr('_', ' ')}.", inputs: }
    end
  end
end
