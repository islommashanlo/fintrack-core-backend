# frozen_string_literal: true

require "rails_helper"

# Every expectation below was read off the real filing it names.
RSpec.describe Form4Parser do
  def parse(name)
    described_class.parse(form4_xml(name))
  end

  describe "a single open-market purchase" do
    subject(:doc) { parse(:simple_purchase) }

    it "reads the document, issuer and owner" do
      expect(doc.document_type).to eq("4")
      expect(doc).not_to be_amendment
      expect(doc.schema_version).to eq("X0609")
      expect(doc.period_of_report).to eq(Date.new(2026, 9, 29))
      expect(doc.date_of_original_submission).to be_nil
      expect(doc.aff10b5_one).to be(false)
      expect(doc.issuer).to eq(Form4Parser::Issuer.new(cik: "0001793855", name: "abrdn Global Infrastructure Income Fund", ticker: "ASGI"))
      expect(doc.owners).to contain_exactly(
        have_attributes(cik: "0001335891", name: "Baird Gordon A", is_director: true, is_officer: false,
                        is_ten_percent_owner: false, is_other: false, officer_title: nil)
      )
    end

    it "reads the transaction exactly as reported" do
      expect(doc.transactions).to contain_exactly(
        have_attributes(
          security_table: "non_derivative", txn_seq: 1, security_title: "Common Stock",
          transaction_date: Date.new(2026, 9, 29), transaction_code: "P", transaction_form_type: "4",
          equity_swap_involved: false, shares: BigDecimal("32"), price: BigDecimal("19.13"),
          acquired_disposed: "A", shares_owned_following: BigDecimal("545"), direct_or_indirect: "D",
          nature_of_ownership: nil, footnote_ids: []
        )
      )
    end
  end

  it "keeps the weighted-average price as reported and links its footnote" do
    doc = parse(:weighted_average_purchase)
    txn = doc.transactions.sole

    expect(txn).to have_attributes(transaction_code: "P", shares: BigDecimal("93091"), price: BigDecimal("0.84"),
                                   direct_or_indirect: "I", nature_of_ownership: "By Trust", footnote_ids: [ "F1" ])
    expect(doc.footnotes.fetch("F1")).to include("weighted average price", "$0.82 to $0.85")
    expect(doc.owners.sole).to have_attributes(is_director: true, is_officer: true, officer_title: "President & CEO")
  end

  describe "a filing with both tables" do
    subject(:doc) { parse(:multi_transaction) }

    it "numbers transactions separately within each table" do
      expect(doc.transactions.map { |t| [ t.security_table, t.txn_seq, t.transaction_code ] }).to eq(
        [
          [ "non_derivative", 1, "C" ], [ "non_derivative", 2, "C" ], [ "non_derivative", 3, "C" ],
          [ "non_derivative", 4, "C" ], [ "non_derivative", 5, "P" ],
          [ "derivative", 1, "C" ], [ "derivative", 2, "C" ], [ "derivative", 3, "C" ], [ "derivative", 4, "C" ]
        ]
      )
    end

    it "leaves a price nil when the filer reported only a footnote" do
      conversion, purchase = doc.transactions.values_at(0, 4)

      expect(conversion).to have_attributes(shares: BigDecimal("7127019"), price: nil, footnote_ids: %w[F1 F3 F4])
      expect(purchase).to have_attributes(shares: BigDecimal("61516"), price: BigDecimal("17.00"), footnote_ids: %w[F2 F3 F4])
    end

    it "reads the derivative-only columns" do
      expect(doc.transactions[5]).to have_attributes(
        security_table: "derivative", security_title: "Series A Preferred Stock", acquired_disposed: "D",
        price: BigDecimal("0"), shares_owned_following: BigDecimal("0"), conversion_or_exercise_price: nil,
        exercise_date: nil, expiration_date: nil, underlying_security_title: "Common Stock",
        underlying_security_shares: BigDecimal("7127019")
      )
    end
  end

  it "reads every reporting owner of a joint filing, and booleans written as true/false" do
    doc = parse(:joint_filers)

    expect(doc.owners.map(&:cik)).to eq(%w[0001362558 0001790748 0001790749 0002042774])
    expect(doc.owners).to all(have_attributes(is_ten_percent_owner: true, is_director: false, is_officer: false))
    expect(doc.issuer.ticker).to eq("NONE")
    expect(doc.transactions.sole).to have_attributes(shares: BigDecimal("955608.711"), price: BigDecimal("23.42"))
  end

  it "parses a filing with only derivative transactions" do
    doc = parse(:derivative_only)

    expect(doc.aff10b5_one).to be(true)
    expect(doc.transactions.map(&:security_table).uniq).to eq([ "derivative" ])
    expect(doc.transactions.map(&:txn_seq)).to eq([ 1, 2, 3, 4, 5, 6 ])
    expect(doc.transactions.first).to have_attributes(
      transaction_code: "S", transaction_date: Date.new(2026, 9, 28), shares: BigDecimal("4903"),
      price: BigDecimal("95.48"), shares_owned_following: BigDecimal("36620615"),
      underlying_security_title: "Common Shares, no par value", underlying_security_shares: nil
    )
  end

  it "reads an amendment and the date of the filing it amends" do
    amendment = parse(:amendment)
    original = parse(:amendment_original)

    expect(amendment).to be_amendment
    expect(amendment.date_of_original_submission).to eq(Date.new(2026, 9, 11))
    expect(amendment.period_of_report).to eq(original.period_of_report)
    expect(amendment.transactions.sole.shares).to eq(BigDecimal("7946"))
    expect(original.transactions.sole.shares).to eq(BigDecimal("7899"))
    expect(amendment.transactions.sole).to have_attributes(conversion_or_exercise_price: BigDecimal("0"), nature_of_ownership: nil)
  end

  it "returns no transactions for a filing that only lists holdings" do
    doc = parse(:holdings_only)

    expect(doc.transactions).to be_empty
    expect(doc.owners.sole).to have_attributes(is_director: true, is_officer: true, is_ten_percent_owner: true,
                                               is_other: true, officer_title: "CEO")
  end

  it "reads the 10b5-1 box and keeps a gift's reported price of zero" do
    expect(parse(:planned_sales).aff10b5_one).to be(true)
    expect(parse(:planned_sales).transactions.map(&:price)).to eq([ BigDecimal("948.50"), BigDecimal("945") ])
    expect(parse(:gift).transactions.sole).to have_attributes(transaction_code: "G", price: BigDecimal("0"))
  end

  it "is pure: parsing touches neither the database nor the network" do
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }

    FilingFixtures::FORM4.each_key { |name| parse(name) }

    expect(queries).to be_empty
    expect(a_request(:any, //)).not_to have_been_made
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe "malformed input" do
    let(:xml) { form4_xml(:simple_purchase) }

    it "raises MalformedError, never a low-level error" do
      {
        "" => /empty document/,
        "<ownershipDocument><issuer>" => /invalid XML/,
        "<somethingElse/>" => /not ownershipDocument/,
        xml.sub(%r{<issuerCik>.*?</issuerCik>}, "") => /missing issuerCik/,
        xml.sub(%r{<reportingOwner>.*</reportingOwner>}m, "") => /no reportingOwner/,
        xml.sub("<value>32</value>", "<value>thirty-two</value>") => /transactionShares is not a number/,
        xml.sub("<value>2026-09-29</value>", "<value>09/29/2026</value>") => /transactionDate is not a date/,
        xml.sub("<isDirector>1</isDirector>", "<isDirector>yes</isDirector>") => /isDirector is not a boolean/
      }.each do |input, message|
        expect { described_class.parse(input) }.to raise_error(Form4Parser::MalformedError, message)
      end
    end

    it "keeps a transaction whose code is missing rather than dropping it" do
      doc = described_class.parse(xml.sub(%r{<transactionCode>P</transactionCode>}, ""))

      expect(doc.transactions.sole.transaction_code).to be_nil
    end

    it "accepts a date carrying a zone offset" do
      doc = described_class.parse(xml.sub("<value>2026-09-29</value>", "<value>2026-09-29-05:00</value>"))

      expect(doc.transactions.sole.transaction_date).to eq(Date.new(2026, 9, 29))
    end
  end
end
