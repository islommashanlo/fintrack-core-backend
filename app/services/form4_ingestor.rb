# frozen_string_literal: true

# Writes one parsed Form 4 to the database. Idempotent (invariant 2): running it again
# for the same filing changes no row counts, because every write is an upsert on a
# natural key backed by a unique index.
class Form4Ingestor
  class MismatchError < StandardError; end

  def self.call(filing:, document:, header:)
    new(filing:, document:, header:).call
  end

  def initialize(filing:, document:, header:)
    @filing = filing
    @document = document
    @header = header
  end

  def call
    verify!

    Filing.transaction do
      upsert_filers
      update_filing
      upsert_transactions
      AmendmentMatcher.after_ingest(@filing)
    end

    @filing
  end

  private

  def verify!
    unless @header.accession_no == @filing.accession_no
      raise MismatchError, "expected #{@filing.accession_no}, submission is #{@header.accession_no}"
    end
    return if Filing::FORM4_TYPES.include?(@document.document_type)

    raise MismatchError, "expected a Form 4, document type is #{@document.document_type.inspect}"
  end

  # A filing may list the same reporting owner twice. Each owner must produce one row
  # per transaction, or the upsert would hit the same natural key twice in one statement
  # (PG::CardinalityViolation).
  def owners
    @owners ||= @document.owners.uniq(&:cik)
  end

  # Names are kept as first seen; the as-reported names live on filings and transactions.
  def upsert_filers
    issuer = @document.issuer
    rows = owners.map { |o| { cik: o.cik, name: o.name || o.cik, filer_type: "insider" } }
    rows << { cik: issuer.cik, name: issuer.name || issuer.cik, filer_type: "issuer" }

    Filer.insert_all(rows.uniq { |r| r[:cik] }, unique_by: :cik)
  end

  def update_filing
    @filing.update!(
      form_type: @header.form_type,
      filed_on: @header.filed_on,
      filed_at: @header.accepted_at,
      accepted_at: @header.accepted_at,
      ingested_at: @filing.ingested_at || Time.current,
      period_of_report: @document.period_of_report,
      issuer_cik: @document.issuer.cik,
      issuer_name: @document.issuer.name,
      issuer_ticker: @document.issuer.ticker,
      owner_ciks: owners.map(&:cik),
      aff10b5_one: @document.aff10b5_one,
      footnotes: @document.footnotes,
      date_of_original_submission: @document.date_of_original_submission,
      parse_status: "parsed",
      parsed_at: Time.current
    )
  end

  def upsert_transactions
    rows = owners.each_with_index.flat_map do |owner, index|
      @document.transactions.map { |txn| row(owner, index + 1, txn) }
    end
    return if rows.empty?

    InsiderTransaction.upsert_all(rows, unique_by: InsiderTransaction::NATURAL_KEY_INDEX)
  end

  def row(owner, owner_seq, txn)
    suspect_reason = PriceCheck.suspect_reason(price: txn.price, transaction_code: txn.transaction_code)

    txn.to_h.merge(
      filing_id: @filing.id,
      accession_no: @filing.accession_no,
      insider_cik: owner.cik,
      insider_name: owner.name,
      owner_seq: owner_seq,
      issuer_cik: @document.issuer.cik,
      issuer_ticker: @document.issuer.ticker,
      is_director: owner.is_director,
      is_officer: owner.is_officer,
      is_ten_percent_owner: owner.is_ten_percent_owner,
      is_other: owner.is_other,
      officer_title: owner.officer_title,
      price_suspect: suspect_reason.present?,
      price_suspect_reason: suspect_reason
    )
  end
end
