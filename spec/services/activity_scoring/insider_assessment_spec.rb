# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActivityScoring::InsiderAssessment do
  let(:time) { Time.utc(2026, 11, 10, 20) }
  let(:transaction) { event(at: time, shares: 30, price: 10, shares_owned_following: 60, is_officer: true) }

  def event(at:, filing_attributes: {}, **attributes)
    filing = create(:filing, filed_at: at, **filing_attributes)
    create(:insider_transaction, filing:, transaction_date: at.in_time_zone("America/New_York").to_date - 1, **attributes)
  end

  def assessment
    described_class.new(transaction:, max_filing_id: Filing.maximum(:id), max_transaction_id: InsiderTransaction.maximum(:id)).call
  end

  def factors
    assessment.fetch(:factors).index_by { |factor| factor.fetch(:id) }
  end

  def history
    [ 10, 20, 30, 40, 50 ].each_with_index { |shares, i| event(at: time - (i + 1).days, shares:, price: 10) }
  end

  it "measures history ties, roles, inferred holdings and participant counts without activating a score" do
    transaction
    history
    event(at: time - 2.days, insider_cik: "0000000789")
    event(at: time, insider_cik: "0000000999")
    result = assessment
    measured = result.fetch(:factors).index_by { |factor| factor.fetch(:id) }
    expect(result).to include(status: "incomplete", score: nil, level: nil, reasons: [], evaluated_at: time)
    expect(result.fetch(:coverage)).to include(available_weight: 75, missing_factors: [ "issuer_scale_and_liquidity" ])
    expect(measured.fetch("own_history")).to include(value: BigDecimal("0.6"), points: 15)
    expect(measured.fetch("own_history").fetch(:inputs)).to include("history_count" => 5, "history_less_or_equal_count" => 3)
    expect(measured.fetch("reported_context")).to include(value: 1, points: 15)
    expect(measured.fetch("position_size_change")).to include(value: 1, points: 20)
    expect(measured.fetch("corroborating_activity")).to include(value: 1, points: 15)
    expect(measured.fetch("lateness").fetch(:inputs)).to include("calendar_days" => 1)
    expect(measured.fetch("lateness").fetch(:points)).to be_within(BigDecimal("0.0000001")).of(BigDecimal("-0.5"))
  end

  it "excludes later reports, same-time history, stale or invalid values and noncanonical rows" do
    transaction
    history
    event(at: time + 1.second)
    event(at: time)
    event(at: time - 365.days)
    event(at: time - 2.days, price: nil)
    event(at: time - 2.days, price: 10, price_suspect: true)
    event(at: time - 2.days, price: -10)
    event(at: time - 2.days, shares: 0)
    event(at: time - 2.days, owner_seq: 2)
    event(at: time - 2.days, security_table: "derivative")
    event(at: time - 2.days, transaction_code: "S")
    event(at: time - 2.days, transaction_date: nil)
    event(at: time - 2.days, transaction_date: time.to_date + 1)
    event(at: time - 2.days, filing_attributes: { parse_status: "failed" })
    event(at: time - 2.days, filing_attributes: { parse_status: "pending" })
    event(at: time - 2.days, filing_attributes: { form_type: "4/A" })
    expect(factors.fetch("own_history").fetch(:inputs)).to include("history_count" => 5, "history_less_or_equal_count" => 3)
  end

  it "uses amendments accepted by the event time and never a later revision" do
    transaction
    original = event(at: time - 3.days, shares: 1)
    revised = event(at: time - 2.days, shares: 1000, filing_attributes: { form_type: "4/A", amends_accession_no: original.accession_no })
    event(at: time + 1.day, shares: 1, filing_attributes: { form_type: "4/A", amends_accession_no: original.accession_no })
    expect(factors.fetch("own_history").fetch(:inputs)).to include("history_count" => 1, "history_less_or_equal_count" => 0,
      "history_first_at" => revised.filing.filed_at)
  end

  it "preserves ID bounds when a backdated transaction or amendment arrives" do
    transaction
    history
    service = described_class.new(transaction:, max_filing_id: Filing.maximum(:id), max_transaction_id: InsiderTransaction.maximum(:id))
    before = service.call
    event(at: time - 3.days, shares: 1)
    event(at: time - 1.day, filing_attributes: { form_type: "4/A", amends_accession_no: transaction.accession_no })
    expect(service.call).to eq(before)
  end

  it "keeps small or unusable histories unavailable without modifying reported prices" do
    transaction.update!(price: 100_000, price_suspect: true)
    history
    expect(factors.fetch("own_history")).to include(status: "unavailable", value: nil, unavailable_reason: "unusable_reported_value")
    expect(transaction.reload.price).to eq(100_000)
    transaction.update!(price: 10, price_suspect: false)
    InsiderTransaction.where.not(id: transaction.id).limit(1).update_all(price: nil)
    expect(factors.fetch("own_history")).to include(status: "unavailable", unavailable_reason: "insufficient_history")
    expect(factors.fetch("own_history").fetch(:inputs)).to include("history_count" => 4)
  end

  it "counts distinct canonical owners by issuer and direction inside the exact rolling boundary" do
    transaction
    event(at: time - 14.days, insider_cik: "0000000789")
    event(at: time - 14.days + 1.second, insider_cik: "0000000999", price: nil)
    event(at: time, insider_cik: "0000000999")
    event(at: time, insider_cik: "0000000111", owner_seq: 2)
    event(at: time, insider_cik: "0000000222", transaction_code: "S")
    event(at: time, insider_cik: "0000000333", issuer_cik: "0000000998")
    event(at: time, insider_cik: "0000000444", security_table: "derivative")
    expect(factors.fetch("corroborating_activity")).to include(value: BigDecimal("0.5"))
    expect(factors.fetch("corroborating_activity").fetch(:inputs)).to include("participant_count" => 2)
  end

  it "infers preceding shares separately for purchases, initial holdings and full sales" do
    expect(factors.fetch("position_size_change").fetch(:inputs)).to include("inferred_prior_shares" => 30)
    transaction.update!(shares_owned_following: 30)
    expect(factors.fetch("position_size_change")).to include(value: 1)
    expect(factors.fetch("position_size_change").fetch(:inputs)).to include("inferred_prior_shares" => 0)
    transaction.update!(transaction_code: "S", acquired_disposed: "D", shares_owned_following: 0)
    expect(factors.fetch("position_size_change")).to include(value: 1)
    transaction.update!(shares_owned_following: 90)
    expect(factors.fetch("position_size_change")).to include(value: BigDecimal("0.25"))
  end

  it "holds out missing or inconsistent holdings rather than inventing a baseline" do
    [ { shares_owned_following: nil }, { shares_owned_following: -1 }, { shares_owned_following: 1 },
      { acquired_disposed: "D" }, { shares: 0 }, { shares: -1 }, { shares: nil } ].each do |attributes|
      transaction.update!(shares: 30, shares_owned_following: 60, acquired_disposed: "A", **attributes)
      expect(factors.fetch("position_size_change")).to include(status: "unavailable", value: nil, points: nil)
    end
  end

  it "uses checked role precedence without interpreting officer title text" do
    transaction.update!(is_officer: false, is_director: true, is_ten_percent_owner: true, officer_title: "CEO")
    expect(factors.fetch("reported_context")).to include(value: BigDecimal("0.75"))
    transaction.update!(is_director: false)
    expect(factors.fetch("reported_context")).to include(value: BigDecimal("0.5"))
    transaction.update!(is_ten_percent_owner: false, is_other: true)
    expect(factors.fetch("reported_context")).to include(value: BigDecimal("0.25"))
    transaction.update!(is_other: false)
    expect(factors.fetch("reported_context")).to include(value: 0, status: "available")
  end

  it "measures Eastern calendar-day staleness without claiming a legal lateness finding" do
    transaction.filing.update!(filed_at: Time.utc(2026, 11, 10, 2))
    transaction.update!(transaction_date: Date.new(2026, 11, 9))
    expect(factors.fetch("lateness")).to include(value: 0, points: 0)
    transaction.update!(transaction_date: Date.new(2026, 10, 10))
    expect(factors.fetch("lateness")).to include(value: 1, points: -15)
    transaction.update!(transaction_date: Date.new(2026, 11, 10))
    expect(factors.fetch("lateness")).to include(status: "unavailable", unavailable_reason: "future_transaction_date")
    transaction.update!(transaction_date: nil)
    expect(factors.fetch("lateness")).to include(status: "unavailable", unavailable_reason: "missing_transaction_date")
  end

  it "does not count a future Eastern transaction date as usable history across a UTC date boundary" do
    transaction
    event(at: Time.utc(2026, 11, 9, 2), transaction_date: Date.new(2026, 11, 9))
    expect(factors.fetch("own_history").fetch(:inputs)).to include("history_count" => 0)
  end

  it "does not assess administrative, derivative, joint-owner or unresolved amendment events" do
    [ { transaction_code: "A" }, { security_table: "derivative" }, { owner_seq: 2 } ].each do |attributes|
      transaction.update!(transaction_code: "P", security_table: "non_derivative", owner_seq: 1, **attributes)
      expect(assessment).to include(status: "ineligible", eligibility_reason: "unsupported_transaction", score: nil)
    end
    transaction.update!(owner_seq: 1)
    transaction.filing.update!(form_type: "4/A")
    expect(assessment).to include(status: "ineligible", eligibility_reason: "unresolved_amendment", score: nil)
  end
end
