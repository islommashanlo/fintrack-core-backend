# frozen_string_literal: true

class WatchlistTransactionCandidates
  def self.sql(filing:, channel:, as_of:)
    raise ArgumentError, "Unsupported channel" unless AlertRule::CHANNELS.include?(channel)

    transactions = Form4ReadScope.new(as_of:).transactions.where(filing_id: filing.id)
    sql = ApplicationRecord.sanitize_sql([ <<~SQL, channel:, filed: filing.filed_at, now: as_of, ticker: filing.issuer_ticker ])
      SELECT DISTINCT ON (rules.id, t.security_table, t.txn_seq, follows.id)
        rules.id AS rule_id, rules.user_id, settings.frequency, settings.revision,
        follows.id AS follow_id, follows.followed_at, follows.target_type, follows.target_key,
        preferences.time_zone, t.id AS insider_transaction_id, t.security_table, t.txn_seq, t.owner_seq
      FROM alert_rules rules
      INNER JOIN alert_rule_settings settings ON settings.alert_rule_id = rules.id
      INNER JOIN follows ON follows.user_id = rules.user_id
      INNER JOIN (WATCHLIST_TRANSACTIONS) t ON (
        (follows.target_type = 'Insider' AND follows.target_key = t.insider_cik)
        OR (follows.target_type = 'Ticker' AND follows.target_key = COALESCE(NULLIF(t.issuer_ticker, ''), :ticker))
      )
      LEFT JOIN notification_preferences preferences ON preferences.user_id = rules.user_id
      WHERE rules.scope = 'watchlist' AND rules.active AND rules.channel = :channel
        AND rules.event_type = 'insider_transaction' AND settings.archived_at IS NULL
        AND follows.removed_at IS NULL AND :filed >= follows.followed_at AND :filed >= settings.enabled_at
        AND (settings.frequency = 'instant' OR preferences.time_zone IS NOT NULL)
        AND (:channel <> 'email' OR (preferences.email_enabled AND preferences.email_enabled_at <= :now
          AND preferences.time_zone IS NOT NULL))
        #{TransactionAlertMatcher.conditions_sql}
      ORDER BY rules.id, t.security_table, t.txn_seq, follows.id, t.owner_seq, t.id
    SQL
    sql.sub("WATCHLIST_TRANSACTIONS") { transactions.to_sql }
  end
end
