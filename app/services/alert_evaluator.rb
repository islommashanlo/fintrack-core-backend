# frozen_string_literal: true

# Matches filing, transaction-line and rolling-cluster rules from local sources.
# SQL resolves membership before source-level deduplication.
class AlertEvaluator
  def self.call(filing)
    new(filing:).call
  end

  def initialize(filing:)
    @filing = filing
  end

  def call
    return [] unless @filing&.parse_status == "parsed"

    enqueue(matching_rules, event_type: "new_filing", unique_by: :index_alert_deliveries_on_alert_rule_id_and_filing_id) +
      enqueue(TransactionAlertMatcher.call(@filing), event_type: "insider_transaction", unique_by: :index_alert_deliveries_on_rule_and_transaction) +
      enqueue(ClusterAlertMatcher.call(@filing), event_type: "cluster", unique_by: :index_alert_deliveries_on_rule_and_cluster)
  end

  private

  def enqueue(matches, event_type:, unique_by:)
    rows = matches.map do |rule|
      { alert_rule_id: rule.fetch("id"), filing_id: rule["filing_id"] || @filing.id, status: "pending", frequency: rule.fetch("frequency"),
        event_type:, rule_revision: rule.fetch("rule_revision"), insider_transaction_id: rule["insider_transaction_id"],
        insider_cluster_snapshot_id: rule["insider_cluster_snapshot_id"],
        created_at: Time.current, updated_at: Time.current }
    end
    return [] if rows.empty?

    inserted = AlertDelivery.insert_all(
      rows,
      unique_by:,
      returning: %w[id frequency]
    )
    inserted.rows.filter_map { |id, frequency| SendAlertJob.perform_later(id) if frequency == "instant" }
  end

  def matching_rules
    sql = case @filing.form_type
    when *Filing::FORM4_TYPES
      form4_sql
    when *Filing::FORM13F_TYPES
      institutional_sql
    else
      return []
    end

    ApplicationRecord.connection.select_all(
      ApplicationRecord.sanitize_sql([ sql, { filing_id: @filing.id, cik: @filing.cik,
                                               issuer_ticker: @filing.issuer_ticker } ])
    ).to_a
  end

  def base_sql
    <<~SQL
      SELECT alert_rules.id, settings.frequency, settings.revision AS rule_revision
      FROM alert_rules
      INNER JOIN follows ON follows.id = alert_rules.follow_id
      INNER JOIN alert_rule_settings settings ON settings.alert_rule_id = alert_rules.id
      WHERE alert_rules.active
        AND follows.removed_at IS NULL AND settings.archived_at IS NULL
        AND alert_rules.event_type = 'new_filing'
        AND alert_rules.channel = 'email'
    SQL
  end

  def form4_sql
    <<~SQL
      #{base_sql}
        AND (
          (follows.target_type = 'Insider' AND EXISTS (
            SELECT 1
            FROM insider_transactions
            WHERE insider_transactions.filing_id = :filing_id
              AND insider_transactions.insider_cik = follows.target_key
          ))
          OR (follows.target_type = 'Ticker' AND (
            follows.target_key = :issuer_ticker
            OR EXISTS (
              SELECT 1
              FROM insider_transactions
              WHERE insider_transactions.filing_id = :filing_id
                AND COALESCE(NULLIF(insider_transactions.issuer_ticker, ''), :issuer_ticker) = follows.target_key
            )
          ))
        )
    SQL
  end

  def institutional_sql
    <<~SQL
      #{base_sql}
        AND follows.target_type = 'InstitutionalFiler'
        AND follows.target_key = :cik
    SQL
  end
end
