# frozen_string_literal: true

class TransactionAlertMatcher
  def self.call(filing, as_of: Time.current, channel: "email")
    query = sql(filing, as_of:, channel:)
    query ? ApplicationRecord.connection.select_all(query).to_a : []
  end

  def self.sql(filing, as_of: Time.current, channel: "email")
    raise ArgumentError, "Unsupported channel" unless AlertRule::CHANNELS.include?(channel)
    return unless filing.form_type.in?(Filing::FORM4_TYPES)

    transactions = Form4ReadScope.new(as_of:).transactions.where(filing_id: filing.id)
    sql = <<~SQL
      SELECT DISTINCT ON (rules.id, t.security_table, t.txn_seq)
        rules.id, settings.frequency, settings.revision AS rule_revision, t.id AS insider_transaction_id, t.security_table, t.txn_seq
      FROM alert_rules rules
      INNER JOIN follows ON follows.id = rules.follow_id
      INNER JOIN alert_rule_settings settings ON settings.alert_rule_id = rules.id
      INNER JOIN (#{transactions.to_sql}) t ON (
        (follows.target_type = 'Insider' AND follows.target_key = t.insider_cik)
        OR (follows.target_type = 'Ticker' AND follows.target_key = COALESCE(NULLIF(t.issuer_ticker, ''), :ticker))
      )
      WHERE rules.active AND rules.event_type = 'insider_transaction' AND rules.channel = :channel
        AND follows.removed_at IS NULL AND settings.archived_at IS NULL
        AND :filed_at >= settings.enabled_at AND :filed_at >= follows.followed_at
        AND (settings.conditions->>'direction' IS NULL OR settings.conditions->>'direction' =
          CASE t.transaction_code WHEN 'P' THEN 'purchase' WHEN 'S' THEN 'sale' ELSE 'other' END)
        AND (settings.conditions->>'type' IS NULL OR settings.conditions->>'type' =
          CASE WHEN t.transaction_code IN ('P', 'S') THEN 'open_market' ELSE 'administrative' END)
        AND (settings.conditions->>'security_table' IS NULL OR settings.conditions->>'security_table' = t.security_table)
        AND (settings.conditions->'codes' IS NULL OR settings.conditions->'codes' @> jsonb_build_array(t.transaction_code))
        AND (settings.conditions->>'role' IS NULL OR CASE settings.conditions->>'role'
          WHEN 'director' THEN t.is_director WHEN 'officer' THEN t.is_officer
          WHEN 'ten_percent_owner' THEN t.is_ten_percent_owner WHEN 'other' THEN t.is_other ELSE false END)
        AND (settings.conditions->>'min_value' IS NULL OR
          (t.price IS NOT NULL AND NOT t.price_suspect AND t.shares * t.price >= (settings.conditions->>'min_value')::numeric))
      ORDER BY rules.id, t.security_table, t.txn_seq, t.owner_seq, t.id
    SQL
    ApplicationRecord.sanitize_sql([ sql, { ticker: filing.issuer_ticker, filed_at: filing.filed_at, channel: } ])
  end
end
