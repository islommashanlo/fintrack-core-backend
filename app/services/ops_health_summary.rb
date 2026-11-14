# frozen_string_literal: true

# Pure interpretation of one operator metrics result; performs no additional I/O.
class OpsHealthSummary
  include OpsHealthChecks
  THRESHOLDS = { poll_age_seconds: 300, ingestion_lag_seconds: 600, pending_age_seconds: 600, queue_tail_age_seconds: 600 }.freeze

  def initialize(metrics:)
    @metrics = metrics.deep_stringify_keys
  end

  def to_h
    checks = poll_checks + form_checks + queue_checks + worker_checks + coverage_checks + notification_checks
    failures = @metrics.fetch("ingestion").fetch("unclassified_parse_failures")
    checks << count_check("unclassified_parse_failures", failures.fetch("unresolved"), failures)
    counts = %w[ok attention unknown].to_h { |status| [ status, checks.count { |check| check.fetch(:status) == status } ] }
    status = counts["attention"].positive? ? "attention" : (counts["unknown"].positive? ? "unknown" : "ok")
    { policy_version: "ops-health-v3", status:, thresholds: THRESHOLDS.merge(OpsNotificationHealth::THRESHOLDS), counts:, checks: }
  end

  private

  def notification_checks
    observations = @metrics["notifications"]
    return [ check("notifications", "unknown", "notifications_not_observed", {}) ] unless observations

    OpsNotificationHealth.new(notifications: observations).checks
  end

  def poll_checks
    @metrics.fetch("ingestion").fetch("pollers").map do |family, observed|
      id = "poll.#{family}"
      if observed.fetch("timestamp_in_future")
        check(id, "attention", "future_poll_timestamp", observed, THRESHOLDS.fetch(:poll_age_seconds))
      else
        threshold_check(id, observed.fetch("seconds_since_last_successful_poll"), THRESHOLDS.fetch(:poll_age_seconds), observed)
      end
    end
  end

  def form_checks
    @metrics.fetch("ingestion").fetch("by_form").flat_map do |form, observed|
      prefix = "form.#{form}"
      total = observed.fetch("filings").fetch("total")
      failures = observed.fetch("parse_failures").merge("failed_filings" => observed.fetch("filings").fetch("failed"))
      lag = observed.fetch("live_ingestion_lag_seconds")
      issues = lag.values_at("missing_filed_at", "negative_lag", "missing_ingested_at_total").sum
      archives = @metrics.fetch("archives").fetch("by_form").fetch(form)
      [ total.zero? ? check("#{prefix}.failures", "unknown", "no_filings", failures) :
          count_check("#{prefix}.failures", [ failures.fetch("unresolved"), failures.fetch("failed_filings") ].max, failures),
        threshold_check("#{prefix}.latency", lag.fetch("filings").positive? ? lag.fetch("p95") : nil,
          THRESHOLDS.fetch(:ingestion_lag_seconds), lag),
        issues.positive? ? count_check("#{prefix}.timing_coverage", issues, lag) :
          check("#{prefix}.timing_coverage", lag.fetch("filings").positive? ? "ok" : "unknown",
            lag.fetch("filings").positive? ? "usable_samples" : "no_live_samples", lag),
        backlog_check(prefix, observed.fetch("live_backlog")), archive_check(prefix, archives) ]
    end
  end

  def backlog_check(prefix, observed)
    id = "#{prefix}.backlog"
    return check(id, "attention", "future_acceptance_timestamp", observed) if observed.fetch("future_filed_at").positive?
    return check(id, "ok", "no_live_pending", observed) if observed.fetch("pending").zero?

    threshold_check(id, observed.fetch("oldest_detected_age_seconds"), THRESHOLDS.fetch(:pending_age_seconds), observed)
  end

  def archive_check(prefix, observed)
    id = "#{prefix}.archive_references"
    missing = observed.fetch("missing_paths") + observed.fetch("missing_reports")
    return count_check(id, missing, observed) if missing.positive?
    return check(id, "unknown", "no_required_documents", observed) if observed.fetch("expected_documents").zero?

    check(id, "ok", "required_references_recorded", observed)
  end

  def queue_checks
    ready = @metrics.fetch("queues").fetch("ready").map do |name, observed|
      id = "queue.#{name}"
      case observed.fetch("latency_status")
      when "empty" then check(id, "ok", "no_ready_jobs", observed)
      when "known" then threshold_check(id, observed.fetch("tail_age_seconds"), THRESHOLDS.fetch(:queue_tail_age_seconds), observed)
      when "invalid_payload", "invalid_timestamp", "future_timestamp"
        check(id, "attention", observed.fetch("latency_status"), observed)
      else check(id, "unknown", observed.fetch("latency_status"), observed)
      end
    end
    sets = @metrics.fetch("queues").fetch("sets").map do |name, data|
      observed = data.slice("total_count", "due_count", "sampled_count", "truncated", "counts_complete", "malformed_payloads", "unattributed_payloads")
      id = "set.#{name}"
      if data.fetch("malformed_payloads").positive?
        check(id, "attention", "malformed_payloads", observed)
      elsif %w[retry dead].include?(name) && data.fetch("total_count").positive?
        check(id, "attention", "records_require_review", observed, 0)
      else
        check(id, data.fetch("counts_complete") ? "ok" : "unknown",
          data.fetch("counts_complete") ? "counts_attributed" : "incomplete_attribution", observed)
      end
    end
    ready + sets
  end

  def worker_checks
    observed = @metrics["workers"]
    return [ check("workers", "unknown", "not_checked", {}) ] unless observed

    states = observed.fetch("states")
    issues = states.values_at("stale", "future", "missing", "invalid").sum
    status = issues.positive? ? "attention" : (observed.fetch("complete") ? "ok" : "unknown")
    reason = issues.positive? ? "heartbeat_records_require_review" : (observed.fetch("complete") ? "heartbeat_scan_complete" : "partial_heartbeat_scan")
    [ check("workers", status, reason, observed) ] + observed.fetch("queues").map do |name, data|
      active = data.fetch("observed_active_consumers").positive?
      status = active ? "ok" : (data.fetch("coverage_complete") ? "attention" : "unknown")
      reason = active ? "recent_consumer_observed" : (data.fetch("coverage_complete") ? "no_recent_consumer" : "partial_heartbeat_scan")
      check("worker_queue.#{name}", status, reason, data)
    end
  end

  def coverage_checks
    [ check("archive_files", "unknown", "not_checked", { filesystem_checked: @metrics.fetch("archives").fetch("filesystem_checked") }),
      check("unknown_ready_queues", "unknown", "not_checked",
        { unknown_ready_queues_checked: @metrics.fetch("queues").fetch("unknown_ready_queues_checked") }) ]
  end
end
