# frozen_string_literal: true

# Operator-only observations of the local pipeline, not a statement of SEC coverage.
class IngestionMetrics
  WINDOW = 24.hours
  COUNTS = %w[total pending failed parsed skipped parsed_last_24h skipped_last_24h unresolved failed_last_24h
    cohort_filings lag_filings missing_filed_at negative_lag missing_ingested_at_total live_pending live_missing_filed_at live_future_filed_at].freeze

  def initialize(now: Time.current)
    @now = now
  end

  def to_h
    rows = Filing.connection.select_all(sql).to_a.index_by { |row| row.fetch("form_type") }
    {
      window_start: (@now - WINDOW).utc.iso8601, window_end: @now.utc.iso8601,
      pollers: { form4: poller(EdgarPoller.last_success_at), form13f: poller(Edgar13fPoller.last_success_at) },
      by_form: Filing::SEC_INGEST_TYPES.to_h { |form| [ form, form_metrics(rows[form]) ] },
      unclassified_parse_failures: unclassified_failures
    }
  end

  private

  def poller(last)
    future = last && last > @now
    { last_successful_poll_at: last&.utc&.iso8601,
      seconds_since_last_successful_poll: last && !future ? (@now - last).round : nil,
      timestamp_in_future: !!future }
  end

  def form_metrics(row)
    row ||= {}
    counts = COUNTS.to_h { |key| [ key, row[key].to_i ] }
    {
      filings: counts.slice(*%w[total pending failed parsed skipped parsed_last_24h skipped_last_24h]),
      parse_failures: counts.slice("unresolved", "failed_last_24h").merge(
        "rate" => counts["total"].zero? ? nil : counts["unresolved"].fdiv(counts["total"]).round(5)),
      live_ingestion_lag_seconds: {
        filings: counts["lag_filings"], cohort_filings: counts["cohort_filings"],
        median: row["median"]&.round, p95: row["p95"]&.round,
        missing_filed_at: counts["missing_filed_at"], negative_lag: counts["negative_lag"],
        missing_ingested_at_total: counts["missing_ingested_at_total"]
      },
      live_backlog: { pending: counts["live_pending"], missing_filed_at: counts["live_missing_filed_at"],
        future_filed_at: counts["live_future_filed_at"],
        oldest_detected_age_seconds: row["oldest_detected_age"]&.round,
        oldest_acceptance_age_seconds: row["oldest_acceptance_age"]&.round }
    }
  end

  def unclassified_failures
    scope = ParseFailure.unresolved.where.not(accession_no: Filing.where(form_type: Filing::SEC_INGEST_TYPES).select(:accession_no))
    { unresolved: scope.count, failed_last_24h: scope.where(last_failed_at: (@now - WINDOW)..@now).count }
  end

  def sql
    Filing.sanitize_sql([ <<~SQL, forms: Filing::SEC_INGEST_TYPES, start: @now - WINDOW, now: @now ])
      WITH candidates AS (
        SELECT f.*, COALESCE(r.status = 'skipped', false) AS skipped,
          p.accession_no IS NOT NULL AND p.resolved_at IS NULL AS unresolved, p.last_failed_at,
          f.source = 'efts' AND f.parse_status = 'parsed' AND COALESCE(r.status <> 'skipped', true) AS live_parsed,
          f.source = 'efts' AND f.parse_status = 'pending' AS live_pending,
          f.ingested_at BETWEEN :start AND :now AS ingested_in_window,
          CASE WHEN f.filed_at <= f.ingested_at THEN EXTRACT(EPOCH FROM f.ingested_at - f.filed_at) END AS lag
        FROM filings f LEFT JOIN institutional_reports r ON r.filing_id = f.id
        LEFT JOIN parse_failures p ON p.accession_no = f.accession_no
        WHERE f.form_type IN (:forms) AND f.created_at <= :now
      )
      SELECT form_type, COUNT(*) AS total,
        COUNT(*) FILTER (WHERE parse_status = 'pending') AS pending,
        COUNT(*) FILTER (WHERE parse_status = 'failed') AS failed,
        COUNT(*) FILTER (WHERE parse_status = 'parsed' AND NOT skipped) AS parsed,
        COUNT(*) FILTER (WHERE skipped) AS skipped,
        COUNT(*) FILTER (WHERE parse_status = 'parsed' AND NOT skipped AND parsed_at BETWEEN :start AND :now) AS parsed_last_24h,
        COUNT(*) FILTER (WHERE skipped AND parsed_at BETWEEN :start AND :now) AS skipped_last_24h,
        COUNT(*) FILTER (WHERE unresolved) AS unresolved,
        COUNT(*) FILTER (WHERE unresolved AND last_failed_at BETWEEN :start AND :now) AS failed_last_24h,
        COUNT(*) FILTER (WHERE live_parsed AND ingested_in_window) AS cohort_filings,
        COUNT(lag) FILTER (WHERE live_parsed AND ingested_in_window) AS lag_filings,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY lag) FILTER (WHERE live_parsed AND ingested_in_window) AS median,
        percentile_cont(0.95) WITHIN GROUP (ORDER BY lag) FILTER (WHERE live_parsed AND ingested_in_window) AS p95,
        COUNT(*) FILTER (WHERE live_parsed AND ingested_in_window AND filed_at IS NULL) AS missing_filed_at,
        COUNT(*) FILTER (WHERE live_parsed AND ingested_in_window AND filed_at > ingested_at) AS negative_lag,
        COUNT(*) FILTER (WHERE live_parsed AND ingested_at IS NULL) AS missing_ingested_at_total,
        COUNT(*) FILTER (WHERE live_pending) AS live_pending,
        COUNT(*) FILTER (WHERE live_pending AND filed_at IS NULL) AS live_missing_filed_at,
        COUNT(*) FILTER (WHERE live_pending AND filed_at > :now) AS live_future_filed_at,
        EXTRACT(EPOCH FROM :now::timestamp - MIN(created_at) FILTER (WHERE live_pending)) AS oldest_detected_age,
        EXTRACT(EPOCH FROM :now::timestamp - MIN(filed_at) FILTER (WHERE live_pending AND filed_at <= :now)) AS oldest_acceptance_age
      FROM candidates GROUP BY form_type
    SQL
  end
end
