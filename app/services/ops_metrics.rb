# frozen_string_literal: true

require "sidekiq/api"

# Legacy operating counters plus form-scoped ingestion observations and billing.
# Consumers should use ingestion for attributed failures and first-ingest latency.
class OpsMetrics
  WINDOW = 24.hours

  def initialize(now: Time.current)
    @now = now
  end

  def to_h
    last_poll = EdgarPoller.last_success_at

    metrics = {
      generated_at: @now.utc.iso8601,
      last_successful_poll_at: last_poll&.utc&.iso8601,
      seconds_since_last_successful_poll: last_poll && (@now - last_poll).round,
      poller_lag_seconds: poller_lag,
      parse_failures: parse_failures,
      filings: { pending: Filing.form4.pending.count, parsed_last_24h: recent.parsed.count },
      queue_depth: queue_depth,
      queues: QueueMetrics.new(now: @now).to_h,
      ingestion: IngestionMetrics.new(now: @now).to_h,
      archives: ArchiveInventory.new.coverage,
      billing: billing
    }
    metrics.merge(health: OpsHealthSummary.new(metrics:).to_h)
  end

  private

  def billing
    counts = BillingEvent.group(:status).count
    oldest = BillingEvent.where(status: "pending").minimum(:created_at)
    { pending: counts.fetch("pending", 0), failed: counts.fetch("failed", 0),
      needs_review: counts.fetch("needs_review", 0),
      unmatched: BillingEvent.where(reason: "unmatched_customer").count,
      oldest_pending_age_seconds: oldest && [ (@now - oldest).round, 0 ].max,
      checkouts: BillingCheckout.group(:status).count,
      checkouts_without_session: BillingCheckout.where(status: %w[pending open needs_review], stripe_id: nil).count }
  end

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
