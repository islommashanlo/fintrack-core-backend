# frozen_string_literal: true

# Shared result vocabulary for pure operator observation policies.
module OpsHealthChecks
  private

  def check(id, status, reason, observed, threshold = nil)
    { id:, status:, reason:, observed:, threshold: }
  end

  def count_check(id, count, observed)
    check(id, count.positive? ? "attention" : "ok", count.positive? ? "records_require_review" : "none_observed", observed, 0)
  end

  def threshold_check(id, value, threshold, observed)
    return check(id, "unknown", "missing_timing_coverage", observed, threshold) if value.nil?

    exceeded = value > threshold
    check(id, exceeded ? "attention" : "ok", exceeded ? "threshold_exceeded" : "within_threshold", observed, threshold)
  end
end
