# frozen_string_literal: true

# Both channels capture one immutable membership set per reported transaction line.
class WatchlistTransactionMatcher
  def self.call(filing, channel:, as_of: Time.current)
    raise ArgumentError, "Unsupported channel" unless AlertRule::CHANNELS.include?(channel)
    return unless filing&.parse_status == "parsed" && filing.form_type.in?(Filing::FORM4_TYPES)
    return unless filing.filed_at && filing.filed_at <= as_of

    columns, values, conflict, returning, destination = if channel == "email"
      [ "status, watchlist_security_table, watchlist_txn_seq", "'pending', security_table, txn_seq",
        "(alert_rule_id, filing_id, watchlist_security_table, watchlist_txn_seq) WHERE watchlist_txn_seq IS NOT NULL",
        "watchlist_security_table AS security_table, watchlist_txn_seq AS txn_seq", "alert_delivery_id" ]
    else
      [ "security_table, txn_seq, time_zone, available_at", <<~SQL.squish,
        security_table, txn_seq, CASE WHEN frequency = 'daily_digest' THEN time_zone END,
        CASE WHEN frequency = 'instant' THEN :now::timestamp ELSE
          ((date_trunc('day', :now::timestamp AT TIME ZONE 'UTC' AT TIME ZONE time_zone) + interval '7 hours'
            + CASE WHEN (:now::timestamp AT TIME ZONE 'UTC' AT TIME ZONE time_zone)::time >= time '07:00'
              THEN interval '1 day' ELSE interval '0 days' END)
            AT TIME ZONE time_zone AT TIME ZONE 'UTC') END
      SQL
        "(alert_rule_id, filing_id, security_table, txn_seq) WHERE event_type = 'insider_transaction'",
        "security_table, txn_seq", "in_app_notification_id" ]
    end
    table = channel == "email" ? "alert_deliveries" : "in_app_notifications"
    sql = ApplicationRecord.sanitize_sql([ <<~SQL, filing: filing.id, now: as_of ])
      WITH candidates AS MATERIALIZED (WATCHLIST_CANDIDATES), inserted AS (
        INSERT INTO #{table}
          (alert_rule_id, filing_id, event_type, insider_transaction_id, frequency, rule_revision,
            created_at, updated_at, #{columns})
        SELECT DISTINCT ON (rule_id, security_table, txn_seq)
          rule_id, :filing, 'insider_transaction', insider_transaction_id, frequency, revision,
          :now, :now, #{values}
        FROM candidates ORDER BY rule_id, security_table, txn_seq, owner_seq, insider_transaction_id, follow_id
        ON CONFLICT #{conflict} DO NOTHING
        RETURNING id, alert_rule_id, #{returning}
      )
      INSERT INTO watchlist_filing_memberships
        (#{destination}, alert_rule_id, user_id, filing_id, follow_id, followed_at,
          target_type, target_key, created_at, updated_at)
      SELECT inserted.id, candidates.rule_id, candidates.user_id, :filing, candidates.follow_id,
        candidates.followed_at, candidates.target_type, candidates.target_key, :now, :now
      FROM inserted INNER JOIN candidates ON candidates.rule_id = inserted.alert_rule_id
        AND candidates.security_table = inserted.security_table AND candidates.txn_seq = inserted.txn_seq
    SQL
    sql = sql.sub("WATCHLIST_CANDIDATES") { WatchlistTransactionCandidates.sql(filing:, channel:, as_of:) }
    ApplicationRecord.connection.execute(sql)
    WatchlistEmailEnqueue.call(filing_id: filing.id, event_type: "insider_transaction") if channel == "email"
  end
end
