# frozen_string_literal: true

module ActivityScoring
  # Comparison sets are resolved at the event's acceptance time, not request time.
  class InsiderInputsQuery
    def initialize(transaction:, rules:, max_filing_id:, max_transaction_id:)
      @transaction = transaction
      @rules = rules
      @max_filing_id = max_filing_id
      @max_transaction_id = max_transaction_id
    end

    def call
      time = @transaction.filing.filed_at
      scope = Form4ReadScope.new(as_of: time, max_filing_id: @max_filing_id, max_transaction_id: @max_transaction_id)
        .transactions.where(owner_seq: 1, security_table: "non_derivative", transaction_code: @transaction.transaction_code)
        .where("filings.filed_at > ?", time - [ @rules.fetch("history_days"), ActivityMethodology.window_days ].max.days)
        .where("insider_transactions.insider_cik = :owner OR insider_transactions.issuer_cik = :issuer",
          owner: @transaction.insider_cik, issuer: @transaction.issuer_cik)
        .where("filings.unmatched_reason IS NULL AND (filings.form_type = '4' OR filings.amends_accession_no IS NOT NULL)")
        .select("insider_transactions.*", "filings.filed_at AS known_at")
      binds = {
        event_id: @transaction.id, owner: @transaction.insider_cik, issuer: @transaction.issuer_cik, time:,
        history_start: time - @rules.fetch("history_days").days,
        window_start: time - ActivityMethodology.window_days.days, value: @transaction.reported_value
      }
      sql = ApplicationRecord.sanitize_sql([ <<~SQL, binds ])
        WITH eligible AS (#{scope.to_sql}), history AS (
          SELECT *, shares * price AS reported_value FROM eligible
          WHERE insider_cik = :owner AND known_at > :history_start AND known_at < :time
            AND shares > 0 AND price > 0 AND NOT price_suspect
            AND transaction_date IS NOT NULL AND transaction_date <= (known_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/New_York')::date
        )
        SELECT EXISTS(SELECT 1 FROM eligible WHERE id = :event_id) AS event_eligible,
          (SELECT COUNT(*) FROM history) AS history_count,
          (SELECT COUNT(*) FROM history WHERE reported_value <= :value) AS history_less_or_equal_count,
          (SELECT MIN(known_at) FROM history) AS history_first_at,
          (SELECT MAX(known_at) FROM history) AS history_last_at,
          (SELECT COUNT(DISTINCT insider_cik) FROM eligible
            WHERE issuer_cik = :issuer AND known_at > :window_start AND known_at <= :time) AS participant_count
      SQL
      Api::V1::CursorPage.sql_rows(sql).sole
    end
  end
end
