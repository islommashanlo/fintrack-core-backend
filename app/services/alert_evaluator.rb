# frozen_string_literal: true

# Finds active rules that match one parsed filing and creates at most one
# delivery per rule and filing. Matching stays in SQL so a filing with many
# owners cannot trigger Ruby-side scans or duplicate deliveries.
class AlertEvaluator
  def self.call(filing)
    new(filing:).call
  end

  def initialize(filing:)
    @filing = filing
  end

  def call
    return [] unless @filing&.parse_status == "parsed"

    rows = matching_rules.map do |rule|
      { alert_rule_id: rule.fetch("id"), filing_id: @filing.id, status: "pending", frequency: rule.fetch("frequency"),
        created_at: Time.current, updated_at: Time.current }
    end
    return [] if rows.empty?

    inserted = AlertDelivery.insert_all(
      rows,
      unique_by: :index_alert_deliveries_on_alert_rule_id_and_filing_id,
      returning: %w[id frequency]
    )
    inserted.rows.filter_map { |id, frequency| SendAlertJob.perform_later(id) if frequency == "instant" }
  end

  private

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
      SELECT alert_rules.id, settings.frequency
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
