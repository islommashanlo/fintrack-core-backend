# frozen_string_literal: true

# Stored notification outcomes, not recipient receipt or a provider acknowledgment.
class NotificationMetrics
  def initialize(now: Time.current)
    @now = now
  end

  def to_h
    sql = NotificationMetricsSql.new(now: @now)
    rows = ApplicationRecord.connection.select_all(sql.outboxes).to_a.index_by { |row| [ row.fetch("channel"), row.fetch("frequency") ] }
    channels = %w[email in_app].to_h do |channel|
      [ channel, { completion_event: channel == "email" ? "recorded_mailer_return" : "row_published",
        receipt_observed: false, failure_status_recorded: channel == "email", failure_timestamp_recorded: false,
        pending_eligibility_checked: channel == "in_app",
        by_frequency: AlertRuleSetting::FREQUENCIES.to_h do |frequency|
          [ frequency, frequency_metrics(rows[[ channel, frequency ]] || {}, channel:, frequency:) ]
        end } ]
    end
    digest = ApplicationRecord.connection.select_one(sql.digests).transform_values { |value| value&.round }
    { window_start: (@now - 24.hours).utc.iso8601, window_end: @now.utc.iso8601,
      channels: channels.merge("push" => { supported: false, receipt_observed: false }), digest_batches: digest }
  end

  private

  def frequency_metrics(row, channel:, frequency:)
    counts = %w[total pending failed completed completed_last_24h missing_completion_timestamp_total future_completion_timestamp_total]
      .to_h { |key| [ key, row[key].to_i ] }
    result = { rows: counts, oldest_pending_age_seconds: row["oldest_pending_age_seconds"]&.round,
      completion_lag_seconds: timing(row, "completion"),
      instant_sec_lag_seconds: frequency == "instant" ? timing(row, "sec").merge(missing_filed_at: row["sec_missing_filed_at"].to_i) : nil }
    if channel == "in_app"
      result.merge!(publication_delay_seconds: timing(row, "publication"),
        raw_due_pending: row["raw_due_pending"].to_i, future_pending: row["future_pending"].to_i,
        eligible_due_pending: row["eligible_due_pending"].to_i,
        oldest_eligible_due_age_seconds: row["oldest_eligible_due_age_seconds"]&.round)
    end
    result
  end

  def timing(row, prefix)
    { cohort_rows: row["#{prefix}_cohort"].to_i, samples: row["#{prefix}_samples"].to_i,
      negative_lag: row["#{prefix}_negative"].to_i, median: row["#{prefix}_median"]&.round, p95: row["#{prefix}_p95"]&.round }
  end
end
