# frozen_string_literal: true

class NotificationMetricsSql
  def initialize(now:)
    @now = now
  end

  def outboxes
    eligible = InAppNotificationPolicy.pending(as_of: @now).select("in_app_notifications.id")
    <<~SQL
      WITH eligible AS (#{eligible.to_sql}), outboxes AS (
        SELECT 'email' AS channel, d.frequency, d.created_at, d.delivered_at AS completed_at,
          d.status = 'sent' AS completed, d.status = 'pending' AS pending, d.status = 'failed' AS failed,
          NULL::timestamp AS available_at, false AS eligible_pending, d.event_type, f.filed_at, f.source
        FROM alert_deliveries d LEFT JOIN filings f ON f.id = d.filing_id WHERE d.created_at <= #{now}
        UNION ALL
        SELECT 'in_app', n.frequency, n.created_at, n.published_at,
          n.published_at IS NOT NULL, n.published_at IS NULL, false, n.available_at,
          EXISTS (SELECT 1 FROM eligible e WHERE e.id = n.id), n.event_type, f.filed_at, f.source
        FROM in_app_notifications n LEFT JOIN filings f ON f.id = n.filing_id WHERE n.created_at <= #{now}
      ), timed AS (
        SELECT *, completed AND completed_at BETWEEN #{start} AND #{now} AS recent_completion,
          EXTRACT(EPOCH FROM completed_at - created_at) AS completion_lag,
          EXTRACT(EPOCH FROM completed_at - available_at) AS publication_delay,
          EXTRACT(EPOCH FROM completed_at - filed_at) AS sec_lag,
          frequency = 'instant' AND event_type IN ('new_filing', 'insider_transaction') AND source = 'efts' AS direct_sec
        FROM outboxes
      )
      SELECT channel, frequency, COUNT(*) AS total,
        COUNT(*) FILTER (WHERE pending) AS pending, COUNT(*) FILTER (WHERE failed) AS failed,
        COUNT(*) FILTER (WHERE completed) AS completed,
        COUNT(*) FILTER (WHERE recent_completion) AS completed_last_24h,
        COUNT(*) FILTER (WHERE completed AND completed_at IS NULL) AS missing_completion_timestamp_total,
        COUNT(*) FILTER (WHERE completed AND completed_at > #{now}) AS future_completion_timestamp_total,
        EXTRACT(EPOCH FROM #{now}::timestamp - MIN(created_at) FILTER (WHERE pending)) AS oldest_pending_age_seconds,
        COUNT(*) FILTER (WHERE pending AND available_at <= #{now}) AS raw_due_pending,
        COUNT(*) FILTER (WHERE pending AND available_at > #{now}) AS future_pending,
        COUNT(*) FILTER (WHERE pending AND eligible_pending AND available_at <= #{now}) AS eligible_due_pending,
        EXTRACT(EPOCH FROM #{now}::timestamp - MIN(available_at) FILTER (WHERE pending AND eligible_pending AND available_at <= #{now})) AS oldest_eligible_due_age_seconds,
        #{timing('completion', 'completion_lag')},
        #{timing('publication', 'publication_delay', condition: "channel = 'in_app'")},
        #{timing('sec', 'sec_lag', condition: 'direct_sec')},
        COUNT(*) FILTER (WHERE recent_completion AND direct_sec AND filed_at IS NULL) AS sec_missing_filed_at
      FROM timed GROUP BY channel, frequency
    SQL
  end

  def digests
    <<~SQL
      SELECT COUNT(*) AS total,
        #{AlertDigestBatch::STATUSES.map { |status| "COUNT(*) FILTER (WHERE status = '#{status}') AS #{status}" }.join(', ')},
        COUNT(*) FILTER (WHERE status = 'sent' AND delivered_at BETWEEN #{start} AND #{now}) AS sent_last_24h,
        COUNT(*) FILTER (WHERE status = 'sending' AND started_at IS NULL) AS sending_missing_start_timestamp,
        COUNT(*) FILTER (WHERE status = 'sending' AND started_at > #{now}) AS sending_future_start_timestamp,
        COUNT(*) FILTER (WHERE status = 'sent' AND delivered_at IS NULL) AS sent_missing_completion_timestamp,
        COUNT(*) FILTER (WHERE status = 'sent' AND delivered_at > #{now}) AS sent_future_completion_timestamp,
        EXTRACT(EPOCH FROM #{now}::timestamp - MIN(created_at) FILTER (WHERE status = 'pending')) AS oldest_pending_age_seconds,
        EXTRACT(EPOCH FROM #{now}::timestamp - MIN(started_at) FILTER (WHERE status = 'sending' AND started_at <= #{now})) AS oldest_sending_age_seconds
      FROM alert_digest_batches WHERE created_at <= #{now}
    SQL
  end

  private

  def now = ApplicationRecord.connection.quote(@now)
  def start = ApplicationRecord.connection.quote(@now - 24.hours)

  def timing(prefix, expression, condition: "TRUE")
    filter = "recent_completion AND #{condition}"
    <<~SQL.squish
      COUNT(*) FILTER (WHERE #{filter}) AS #{prefix}_cohort,
      COUNT(#{expression}) FILTER (WHERE #{filter} AND #{expression} >= 0) AS #{prefix}_samples,
      COUNT(*) FILTER (WHERE #{filter} AND #{expression} < 0) AS #{prefix}_negative,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY #{expression}) FILTER (WHERE #{filter} AND #{expression} >= 0) AS #{prefix}_median,
      percentile_cont(0.95) WITHIN GROUP (ORDER BY #{expression}) FILTER (WHERE #{filter} AND #{expression} >= 0) AS #{prefix}_p95
    SQL
  end
end
