# frozen_string_literal: true

class FilingFollowMatch
  def self.sql(filing)
    if Filing::FORM4_TYPES.include?(filing.form_type)
      ApplicationRecord.sanitize_sql([ <<~SQL.squish, id: filing.id, ticker: filing.issuer_ticker ])
        ((follows.target_type = 'Insider' AND EXISTS (
          SELECT 1 FROM insider_transactions t WHERE t.filing_id = :id AND t.insider_cik = follows.target_key
        )) OR (follows.target_type = 'Ticker' AND (follows.target_key = :ticker OR EXISTS (
          SELECT 1 FROM insider_transactions t WHERE t.filing_id = :id
            AND COALESCE(NULLIF(t.issuer_ticker, ''), :ticker) = follows.target_key
        ))))
      SQL
    elsif Filing::FORM13F_TYPES.include?(filing.form_type)
      ApplicationRecord.sanitize_sql([ "follows.target_type = 'InstitutionalFiler' AND follows.target_key = ?", filing.cik ])
    else
      "FALSE"
    end
  end
end
