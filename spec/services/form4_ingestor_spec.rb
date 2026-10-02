# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form4Ingestor do
  def document_for(name)
    Form4Parser.parse(form4_xml(name))
  end

  def snapshot
    {
      filers: Filer.order(:cik).map { |r| r.attributes.except("id", "created_at", "updated_at") },
      filings: Filing.order(:accession_no).map { |r| r.attributes.except("id", "created_at", "updated_at", "parsed_at") },
      transactions: InsiderTransaction.order(*InsiderTransaction::NATURAL_KEY)
                                      .map { |r| r.attributes.except("id", "created_at", "updated_at") }
    }
  end

  it "fills in the filing from the submission header and the document" do
    filing = ingest_form4(:simple_purchase)

    expect(filing.reload).to have_attributes(
      parse_status: "parsed", form_type: "4", filed_on: Date.new(2026, 9, 30),
      filed_at: Time.utc(2026, 9, 30, 15, 31, 37), period_of_report: Date.new(2026, 9, 29),
      issuer_cik: "0001793855", issuer_name: "abrdn Global Infrastructure Income Fund", issuer_ticker: "ASGI",
      owner_ciks: [ "0001335891" ], aff10b5_one: false, date_of_original_submission: nil
    )
    expect(filing.parsed_at).to be_present
  end

  it "stores the transaction with the owner's relationship flags" do
    ingest_form4(:simple_purchase)

    expect(InsiderTransaction.sole).to have_attributes(
      accession_no: "0001104659-26-112212", insider_cik: "0001335891", insider_name: "Baird Gordon A",
      owner_seq: 1, issuer_cik: "0001793855", issuer_ticker: "ASGI", security_table: "non_derivative",
      txn_seq: 1, transaction_code: "P", shares: BigDecimal("32"), price: BigDecimal("19.13"),
      acquired_disposed: "A", is_director: true, is_officer: false, price_suspect: false,
      price_suspect_reason: nil
    )
  end

  it "records the issuer and each owner as filers" do
    ingest_form4(:simple_purchase)

    expect(Filer.pluck(:cik, :filer_type)).to contain_exactly(%w[0001335891 insider], %w[0001793855 issuer])
  end

  it "is idempotent: re-ingesting every fixture changes nothing" do
    FilingFixtures::FORM4.each_key { |name| ingest_form4(name) }
    before = snapshot

    FilingFixtures::FORM4.each_key { |name| ingest_form4(name) }

    expect(snapshot).to eq(before)
    expect(InsiderTransaction.count).to eq(1 + 1 + 9 + 4 + 6 + 1 + 1 + 0 + 2 + 1)
  end

  it "writes one row per reporting owner for a joint filing" do
    ingest_form4(:joint_filers)

    rows = InsiderTransaction.order(:owner_seq)
    expect(rows.map { |r| [ r.owner_seq, r.insider_cik, r.txn_seq ] }).to eq(
      [ [ 1, "0001362558", 1 ], [ 2, "0001790748", 1 ], [ 3, "0001790749", 1 ], [ 4, "0002042774", 1 ] ]
    )
    expect(rows).to all(have_attributes(is_ten_percent_owner: true, shares: BigDecimal("955608.711")))
  end

  it "keeps missing prices as NULL and footnote references on the row" do
    filing = ingest_form4(:multi_transaction)

    conversion = InsiderTransaction.find_by!(security_table: "non_derivative", txn_seq: 1)
    expect(conversion).to have_attributes(price: nil, price_suspect: false, footnote_ids: %w[F1 F3 F4])
    expect(filing.footnotes.keys).to eq(%w[F1 F2 F3 F4])
    expect(InsiderTransaction.where(security_table: "derivative").count).to eq(4)
  end

  it "marks a holdings-only filing parsed with no transactions" do
    filing = ingest_form4(:holdings_only)

    expect(filing).to have_attributes(parse_status: "parsed", owner_ciks: [ "0001813372" ])
    expect(InsiderTransaction.count).to eq(0)
  end

  # Regression: in July, two rows in one upsert batch shared a natural key and Postgres
  # raised PG::CardinalityViolation. A filing that lists the same owner twice does that.
  it "does not collide when a filing lists the same reporting owner twice" do
    document = document_for(:multi_transaction)
    doubled = document.with(owners: document.owners + document.owners)

    expect { ingest_form4(:multi_transaction, document: doubled) }.not_to raise_error
    expect(InsiderTransaction.count).to eq(9)
    expect(Filing.sole.owner_ciks).to eq([ "0001706399" ])
  end

  describe "suspect prices" do
    def with_price(name, price)
      document = document_for(name)
      document.with(transactions: document.transactions.map { |t| t.with(price: BigDecimal(price)) })
    end

    it "flags an implausible price and stores it exactly as reported" do
      ingest_form4(:simple_purchase, document: with_price(:simple_purchase, "612.16"))
      expect(InsiderTransaction.sole).to have_attributes(price_suspect: false)

      ingest_form4(:simple_purchase, document: with_price(:simple_purchase, "61216.00"))
      expect(InsiderTransaction.sole).to have_attributes(
        price: BigDecimal("61216.00"), price_suspect: true, price_suspect_reason: "over_50k_per_share"
      )
    end

    it "does not flag a gift reported at zero, but does flag a zero-price purchase" do
      ingest_form4(:gift)
      ingest_form4(:simple_purchase, document: with_price(:simple_purchase, "0"))

      expect(InsiderTransaction.find_by!(transaction_code: "G")).to have_attributes(price: 0, price_suspect: false)
      expect(InsiderTransaction.find_by!(transaction_code: "P")).to have_attributes(
        price: 0, price_suspect: true, price_suspect_reason: "zero_on_open_market_code"
      )
    end
  end

  it "refuses a submission that belongs to a different filing, writing nothing" do
    filing = create(:filing, :pending)
    submission = Edgar::Submission.parse(form4_submission(:simple_purchase))

    expect do
      described_class.call(filing:, document: document_for(:simple_purchase), header: submission.header)
    end.to raise_error(Form4Ingestor::MismatchError)

    expect(filing.reload.parse_status).to eq("pending")
    expect(InsiderTransaction.count).to eq(0)
    expect(Filer.count).to eq(0)
  end
end
