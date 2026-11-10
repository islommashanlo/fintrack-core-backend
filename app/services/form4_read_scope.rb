# frozen_string_literal: true

# Read-only Form 4 visibility and amendment resolution shared by API queries.
class Form4ReadScope
  def initialize(as_of:, max_filing_id: nil, max_transaction_id: nil)
    @as_of = as_of
    @max_filing_id = max_filing_id
    @max_transaction_id = max_transaction_id
  end

  def visible_filings
    scope = Filing.form4.parsed.where("filings.filed_at <= ?", @as_of)
    scope = scope.where("filings.id <= ?", @max_filing_id) if @max_filing_id
    scope
  end

  def effective_filings
    visible_filings.where(<<~SQL, as_of: @as_of, max_filing_id: @max_filing_id)
      NOT EXISTS (
        SELECT 1 FROM filings later
        WHERE later.amends_accession_no = COALESCE(filings.amends_accession_no, filings.accession_no)
          AND later.parse_status = 'parsed'
          AND later.form_type IN ('4', '4/A')
          #{@max_filing_id ? 'AND later.id <= :max_filing_id' : ''}
          AND later.filed_at <= :as_of
          AND (later.filed_at, later.accession_no) > (filings.filed_at, filings.accession_no)
      )
    SQL
  end

  def transactions(effective: true)
    scope = InsiderTransaction.joins(:filing).merge(effective ? effective_filings : visible_filings)
    scope = scope.where("insider_transactions.id <= ?", @max_transaction_id) if @max_transaction_id
    scope
  end

  def owner_filings(cik)
    visible_filings.where("filings.owner_ciks @> ARRAY[?]::varchar[] OR filings.id IN (?)",
                           cik, transactions(effective: false).where(insider_cik: cik).select(:filing_id))
  end
end
