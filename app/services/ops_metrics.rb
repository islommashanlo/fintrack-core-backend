# frozen_string_literal: true

require "sidekiq/api"

# The operating numbers the brief asks for in Phase 2: poller lag, parse failure rate,
# queue depth and the time of the last successful poll.
class OpsMetrics
  WINDOW = 24.hours

  def initialize(now: Time.current)
    @now = now
  end

  def to_h
    last_poll = EdgarPoller.last_success_at

    {
      generated_at: @now.utc.iso8601,
      last_successful_poll_at: last_poll&.utc&.iso8601,
      seconds_since_last_successful_poll: last_poll && (@now - last_poll).round,
      poller_lag_seconds: poller_lag,
      parse_failures: parse_failures,
      filings: { pending: Filing.form4.pending.count, parsed_last_24h: recent.parsed.count },
      queue_depth: queue_depth
    }
  end

  private

  def recent
    Filing.form4.where(created_at: (@now - WINDOW)..)
  end

  # From the SEC accepting a filing to us having ingested it, for filings the live
  # poller found in the last 24 hours. Backfilled filings would only distort this.
  def poller_lag
    row = Filing.connection.select_one(Filing.sanitize_sql([ <<~SQL, @now - WINDOW ]))
      SELECT COUNT(*) AS filings,
             percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM parsed_at - filed_at)) AS median,
             percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM parsed_at - filed_at)) AS p95
      FROM filings
      WHERE source = 'efts' AND parse_status = 'parsed' AND parsed_at >= ? AND filed_at IS NOT NULL
    SQL

    { filings: row["filings"], median: row["median"]&.round, p95: row["p95"]&.round }
  end

  def parse_failures
    unresolved = ParseFailure.unresolved.count
    total = Filing.form4.count

    {
      unresolved:,
      failed_last_24h: ParseFailure.unresolved.where(last_failed_at: (@now - WINDOW)..).count,
      rate: total.zero? ? 0.0 : unresolved.fdiv(total).round(5)
    }
  end

  def queue_depth
    stats = Sidekiq::Stats.new

    { enqueued: stats.enqueued, retries: stats.retry_size, scheduled: stats.scheduled_size, dead: stats.dead_size }
  end
end
