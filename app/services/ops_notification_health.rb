# frozen_string_literal: true

# Interprets recorded application outcomes, never delivery receipt or send eligibility.
class OpsNotificationHealth
  include OpsHealthChecks
  THRESHOLDS = { notification_instant_seconds: 120, notification_due_seconds: 120, digest_sending_seconds: 600 }.freeze

  def initialize(notifications:)
    @notifications = notifications.deep_stringify_keys
  end

  def checks
    channels = @notifications.fetch("channels", {})
    output = %w[email in_app].flat_map do |name|
      data = channels[name]
      next [ check("notifications.#{name}", "unknown", "channel_not_observed", {}) ] unless data

      frequencies = data.fetch("by_frequency").flat_map { |frequency, row| frequency_checks(name, frequency, row, data) }
      frequencies + [ check("notifications.#{name}.receipt", "unknown", "receipt_not_observed",
        data.slice("completion_event", "receipt_observed", "failure_timestamp_recorded")) ]
    end
    output << check("notifications.push", "unknown", "channel_not_measured", channels.fetch("push", {}))
    output + digest_checks
  end

  private

  def frequency_checks(channel, frequency, row, metadata)
    id = "notifications.#{channel}.#{frequency}"
    rows = row.fetch("rows")
    checks = [ failure_check(id, rows, metadata), timestamp_check(id, row), backlog_check(id, row, metadata) ]
    if frequency == "instant"
      checks << latency_check("#{id}.completion_lag", row.fetch("completion_lag_seconds"))
      sec = row.fetch("instant_sec_lag_seconds")
      checks << latency_check("#{id}.sec_lag", sec)
      complete = sec.fetch("cohort_rows").positive? && sec.fetch("missing_filed_at").zero?
      checks << check("#{id}.sec_timing_coverage", complete ? "ok" : "unknown",
        complete ? "acceptance_stamps_recorded" : "incomplete_acceptance_coverage", sec)
    end
    checks
  end

  def failure_check(id, rows, metadata)
    unless metadata.fetch("failure_status_recorded")
      return check("#{id}.failures", "unknown", "failure_status_not_recorded", { failed: rows.fetch("failed") })
    end
    return check("#{id}.failures", "unknown", "no_notification_rows", rows) if rows.fetch("total").zero?

    count_check("#{id}.failures", rows.fetch("failed"), rows)
  end

  def timestamp_check(id, row)
    rows = row.fetch("rows")
    observations = { missing_completion: rows.fetch("missing_completion_timestamp_total"),
      future_completion: rows.fetch("future_completion_timestamp_total"),
      negative_completion: row.fetch("completion_lag_seconds").fetch("negative_lag"),
      negative_sec: row["instant_sec_lag_seconds"]&.fetch("negative_lag"),
      early_publication: row["publication_delay_seconds"]&.fetch("negative_lag") }
    if observations.values.compact.any?(&:positive?)
      check("#{id}.timestamps", "attention", "inconsistent_timestamps", observations)
    elsif rows.fetch("completed").zero?
      check("#{id}.timestamps", "unknown", "no_recorded_completions", observations)
    else
      check("#{id}.timestamps", "ok", "recorded_timestamps_consistent", observations)
    end
  end

  def backlog_check(id, row, metadata)
    unless metadata.fetch("pending_eligibility_checked")
      return check("#{id}.backlog", "unknown", "pending_eligibility_not_checked",
        { raw_pending: row.fetch("rows").fetch("pending"), oldest_raw_pending_age_seconds: row.fetch("oldest_pending_age_seconds") })
    end
    observed = row.slice("raw_due_pending", "eligible_due_pending", "future_pending", "oldest_eligible_due_age_seconds")
    return check("#{id}.backlog", "ok", "no_eligible_due_rows", observed) if row.fetch("eligible_due_pending").zero?

    threshold_check("#{id}.backlog", row.fetch("oldest_eligible_due_age_seconds"), THRESHOLDS.fetch(:notification_due_seconds), observed)
  end

  def latency_check(id, timing)
    threshold_check(id, timing.fetch("samples").positive? ? timing.fetch("p95") : nil,
      THRESHOLDS.fetch(:notification_instant_seconds), timing)
  end

  def digest_checks
    data = @notifications["digest_batches"]
    return [ check("notifications.digest_batches", "unknown", "digest_batches_not_observed", {}) ] unless data

    prefix = "notifications.digest_batches"
    stamps = %w[sending_missing_start_timestamp sending_future_start_timestamp sent_missing_completion_timestamp sent_future_completion_timestamp]
      .to_h { |key| [ key, data.fetch(key) ] }
    timing_status = stamps.values.any?(&:positive?) ? "attention" : (data.fetch("total").zero? ? "unknown" : "ok")
    [ data.fetch("total").zero? ? check("#{prefix}.failures", "unknown", "no_digest_batches", data) :
        count_check("#{prefix}.failures", data.fetch("failed"), data),
      check("#{prefix}.timestamps", timing_status, timing_status == "attention" ? "inconsistent_timestamps" : "observed_timestamp_coverage", stamps),
      data.fetch("sending").zero? ? check("#{prefix}.sending_age", "ok", "no_sending_batches", { sending: 0 }) :
        threshold_check("#{prefix}.sending_age", data.fetch("oldest_sending_age_seconds"), THRESHOLDS.fetch(:digest_sending_seconds),
          data.slice("sending", "oldest_sending_age_seconds", "sending_missing_start_timestamp", "sending_future_start_timestamp")),
      check("#{prefix}.pending_eligibility", "unknown", "pending_eligibility_not_checked",
        data.slice("pending", "oldest_pending_age_seconds")) ]
  end
end
