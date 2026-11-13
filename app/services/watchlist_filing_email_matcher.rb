# frozen_string_literal: true

class WatchlistFilingEmailMatcher
  def self.call(filing, as_of: Time.current)
    return [] unless filing&.parse_status == "parsed" && filing.form_type.in?(Filing::SEC_INGEST_TYPES)
    return [] unless filing.filed_at && filing.filed_at <= as_of

    sql = ApplicationRecord.sanitize_sql([ <<~SQL, filing: filing.id, now: as_of ])
      WITH candidates AS MATERIALIZED (WATCHLIST_CANDIDATES), inserted AS (
        INSERT INTO alert_deliveries
          (alert_rule_id, filing_id, event_type, status, frequency, rule_revision, created_at, updated_at)
        SELECT DISTINCT ON (rule_id) rule_id, :filing, 'new_filing', 'pending', frequency, revision,
          :now, :now FROM candidates ORDER BY rule_id, follow_id
        ON CONFLICT (alert_rule_id, filing_id)
          WHERE insider_transaction_id IS NULL AND insider_cluster_snapshot_id IS NULL
            AND institutional_change_snapshot_id IS NULL AND news_item_id IS NULL DO NOTHING
        RETURNING id, alert_rule_id, frequency
      ), witnesses AS (
        INSERT INTO watchlist_filing_memberships
          (alert_delivery_id, alert_rule_id, user_id, filing_id, follow_id, followed_at,
            target_type, target_key, created_at, updated_at)
        SELECT inserted.id, candidates.rule_id, candidates.user_id, :filing, candidates.follow_id,
          candidates.followed_at, candidates.target_type, candidates.target_key, :now, :now
        FROM inserted INNER JOIN candidates ON candidates.rule_id = inserted.alert_rule_id
        RETURNING alert_delivery_id
      )
      SELECT DISTINCT inserted.id, inserted.frequency FROM inserted
      INNER JOIN witnesses ON witnesses.alert_delivery_id = inserted.id
    SQL
    sql = sql.sub("WATCHLIST_CANDIDATES") { WatchlistFilingCandidates.sql(filing:, channel: "email", as_of:) }
    inserted = Api::V1::CursorPage.sql_rows(sql)
    # Queue outages may leave a committed instant row pending. A capture retry may
    # requeue that row without changing its original membership evidence.
    instant_ids = AlertDelivery.joins(:alert_rule).where(filing_id: filing.id, frequency: "instant", status: "pending",
      alert_rules: { scope: "watchlist", channel: "email", event_type: "new_filing", active: true }).pluck(:id)
    ActiveRecord.after_all_transactions_commit do
      instant_ids.each do |id|
        raise ActiveJob::EnqueueError, "Unable to enqueue watchlist email" unless SendAlertJob.perform_later(id)
      end
    end if instant_ids.any?
    inserted
  end
end
