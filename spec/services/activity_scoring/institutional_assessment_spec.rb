# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActivityScoring::InstitutionalAssessment do
  include InstitutionalReadHelpers
  around { |example| travel_to(Time.utc(2026, 11, 10, 20)) { example.run } }
  let(:fund) { create(:institutional_filer) }
  let(:period) { Date.new(2026, 6, 30) }
  let(:cusip) { "037833100" }

  def report(fund: self.fund, period: self.period, at: nil, positions: [ {} ], **attributes)
    date = period + 45.days
    item = create_13f(fund:, period:, filed_at: at || Time.utc(date.year, date.month, date.day, 20), **attributes)
    rows = positions.map do |position|
      shares = position.fetch(:shares, 100)
      raw = position.fetch(:value_reported, shares * 10)
      unit = position.fetch(:value_unit, "whole_dollars")
      create(:institutional_holding, institutional_report: item, cusip:, shares:, value_reported: raw,
        value_unit: unit, value_usd: raw * (unit == "thousands" ? 1000 : 1), **position)
    end
    item.update!(table_entry_total: rows.length, table_value_total: rows.sum(&:value_reported))
    item
  end

  def page
    Api::V1::CursorPage.new(parameters: { "limit" => "100" }, context: { "resource" => "scoring_test" },
      sorts: Api::V1::ActivityQuery::SORTS, default_sort: "-occurred_at", bounds: Api::V1::ActivityQuery::BOUNDS)
  end

  def row_for(snapshot = page, key: cusip, put_call: nil, share_type: "SH")
    Api::V1::ActivityQuery.new(page: snapshot, filters: { "source" => "institutional" }).call.records.find do |row|
      row["fund_id"] == fund.id && row["period_of_report"] == period && row["cusip"] == key &&
        row["put_call"] == put_call && row["share_type"] == share_type
    end || raise("Missing test activity")
  end

  def assessment(row: row_for, snapshot: page)
    bounds = %w[filings reports holdings].to_h { |key| [ key, snapshot.bound(key) ] }
    described_class.new(row:, bounds:).call
  end

  def measured(result = assessment)
    result.fetch(:factors).index_by { |factor| factor.fetch(:id) }
  end

  def pair(fund: self.fund, before: 100, after: 150, **position)
    previous = report(fund:, period: Date.new(2026, 3, 31), positions: before ? [ { shares: before, **position } ] : [])
    current = report(fund:, positions: after ? [ { shares: after, **position } ] : [])
    [ previous, current ]
  end

  it "measures five historical comparisons, context, share ratios and exact peer participation" do
    shares = 100
    [ Date.new(2024, 12, 31), Date.new(2025, 3, 31), Date.new(2025, 6, 30), Date.new(2025, 9, 30),
      Date.new(2025, 12, 31), Date.new(2026, 3, 31), period ].each_with_index do |quarter, index|
      shares += index * 10
      report(period: quarter, positions: [ { shares: } ])
    end
    2.times { pair(fund: create(:institutional_filer), after: 120) }
    result = assessment
    factors = measured(result)
    expect(result).to include(status: "incomplete", score: nil, level: nil, reasons: [])
    expect(result.fetch(:coverage)).to include(available_weight: 75, missing_factors: [ "issuer_scale_and_liquidity" ])
    expect(result.fetch(:source_coverage)).to include(reports_complete: true, values_complete: true, invalid_report_ids: [])
    expect(factors.fetch("own_history")).to include(value: 1, points: 25)
    expect(factors.fetch("own_history").fetch(:inputs)).to include("history_count" => 5, "history_less_or_equal_count" => 5)
    expect(factors.fetch("reported_context")).to include(value: BigDecimal("0.5"), points: BigDecimal("7.5"))
    expect(factors.fetch("position_size_change")).to include(value: BigDecimal("0.24"), points: BigDecimal("4.8"))
    expect(factors.fetch("corroborating_activity")).to include(value: 1, points: 15)
    expect(factors.fetch("corroborating_activity").fetch(:inputs)).to include("participant_count" => 3)
    expect(factors.fetch("lateness")).to include(value: BigDecimal("0.5"), points: BigDecimal("-7.5"))
  end

  it "uses all of the fund's historical positions, counts ties and excludes the current quarter" do
    keys = [ cusip, "594918104", "02079K305", "023135106", "084670702" ]
    original = keys.map { |key| { cusip: key, shares: 100 } }
    older = keys.each_with_index.map { |key, i| { cusip: key, shares: 100 + (i + 1) * 10 } }
    current = older.map { |position| position.merge(shares: position[:shares] + 30) }
    report(period: Date.new(2025, 12, 31), positions: original)
    report(period: Date.new(2026, 3, 31), positions: older)
    report(positions: current)
    result = measured.fetch("own_history")
    expect(result).to include(value: BigDecimal("0.6"), points: 15)
    expect(result.fetch(:inputs)).to include("history_count" => 5, "history_less_or_equal_count" => 3)
  end

  it "excludes incomplete historical comparisons while retaining a complete current event" do
    shares = 100
    quarters = [ Date.new(2024, 12, 31), Date.new(2025, 3, 31), Date.new(2025, 6, 30), Date.new(2025, 9, 30),
                 Date.new(2025, 12, 31), Date.new(2026, 3, 31), period ]
    reports = quarters.map { |quarter| report(period: quarter, positions: [ { shares: shares += 10 } ]) }
    reports[2].update!(table_entry_total: 2)
    result = assessment
    expect(result.fetch(:source_coverage)).to include(reports_complete: true)
    expect(measured(result).fetch("own_history")).to include(status: "unavailable", unavailable_reason: "insufficient_history")
    expect(measured(result).fetch("own_history").fetch(:inputs)).to include("history_count" => 3)
  end

  it "limits history to eight quarters while retaining the earlier baseline needed at the boundary" do
    report(period: Date.new(2023, 12, 31), positions: [ { shares: 100 } ])
    report(period: Date.new(2024, 3, 31), positions: [ { shares: 110 } ])
    report(period: Date.new(2024, 6, 30), positions: [ { shares: 120 } ])
    pair
    expect(measured.fetch("own_history").fetch(:inputs)).to include("history_count" => 1)
  end

  it "excludes historical comparisons that only became available at the event timestamp" do
    previous, current = pair
    report(period: Date.new(2025, 12, 31), at: current.filing.filed_at, positions: [ { shares: 90 } ])
    expect(measured.fetch("own_history").fetch(:inputs)).to include("history_count" => 0)
    expect(previous.filing.filed_at).to be < current.filing.filed_at
  end

  it "retains the exact event reports and point-in-time peers after later restatements" do
    previous, current = pair
    peer = create(:institutional_filer)
    _peer_previous, peer_current = pair(fund: peer)
    snapshot = page
    row = row_for(snapshot)
    before = assessment(row:, snapshot:)
    report(at: current.filing.filed_at + 1.day, amendment_type: "RESTATEMENT", positions: [ { shares: 5 } ])
    report(fund: peer, at: peer_current.filing.filed_at + 1.day, amendment_type: "RESTATEMENT", positions: [ { shares: 5 } ])
    pair(fund: create(:institutional_filer))
    version = Api::V1::ActivityIdentifier.decode(Api::V1::ActivityIdentifier.encode(row))
    retained = Api::V1::ActivityQuery.new(page: page).find(version)
    expect(retained.fetch("context_report_ids")).to contain_exactly(previous.id, current.id)
    # The newly ingested peer pair has the same acceptance timestamp; fixed ID bounds exclude it.
    expect(assessment(row: retained, snapshot:)).to eq(before)
    expect(measured(assessment(row: retained)).fetch("corroborating_activity").fetch(:inputs)).to include("participant_count" => 3)
  end

  it "pins a signed subject version even when a different revision has the same acceptance timestamp" do
    previous, current = pair
    row = row_for
    before = assessment(row:)
    report(at: current.filing.filed_at, amendment_type: "RESTATEMENT", positions: [ { shares: 1 } ])
    expect(assessment(row:)).to eq(before)
    expect(before.fetch(:source_coverage).fetch(:report_ids)).to contain_exactly(previous.id, current.id)
  end

  it "resolves additive amendments as one position and does not count duplicate rows as extra peers" do
    previous, current = pair(after: 110)
    addition = report(at: current.filing.filed_at + 1.day, amendment_type: "NEW HOLDINGS",
      positions: [ { shares: 10 }, { shares: 20 } ])
    result = assessment
    expect(result.fetch(:source_coverage)).to include(reports_complete: true, values_complete: true)
    expect(result.fetch(:source_coverage).fetch(:report_ids)).to contain_exactly(previous.id, current.id, addition.id)
    expect(measured(result).fetch("position_size_change")).to include(value: BigDecimal("0.4"))
    expect(measured(result).fetch("corroborating_activity").fetch(:inputs)).to include("participant_count" => 1)
  end

  it "separates put/call, share types, opposite directions and exact change types" do
    pair
    pair(fund: create(:institutional_filer), put_call: "CALL")
    pair(fund: create(:institutional_filer), share_type: "PRN")
    pair(fund: create(:institutional_filer), after: 50)
    pair(fund: create(:institutional_filer), before: nil)
    pair(fund: create(:institutional_filer))
    result = measured.fetch("corroborating_activity")
    expect(result).to include(value: BigDecimal("0.5"))
    expect(result.fetch(:inputs)).to include("participant_count" => 2, "cusip" => cusip, "share_type" => "SH", "put_call" => nil)
  end

  it "does not turn missing quarters, notices or unresolved additive amendments into comparable peers" do
    pair
    peer = create(:institutional_filer)
    report(fund: peer, period: Date.new(2025, 12, 31))
    report(fund: peer, positions: [ { shares: 150 } ])
    orphan = create(:institutional_filer)
    report(fund: orphan, period: Date.new(2026, 3, 31))
    report(fund: orphan, amendment_type: "NEW HOLDINGS", positions: [ { shares: 150 } ])
    notice = create(:institutional_filer)
    report(fund: notice, period: Date.new(2026, 3, 31))
    report(fund: notice, submission_type: "13F-NT", positions: [])
    expect(measured.fetch("corroborating_activity").fetch(:inputs)).to include("participant_count" => 1)
  end

  it "excludes peers filed after the evaluation time and those with incomplete reports" do
    _previous, current = pair
    late = create(:institutional_filer)
    report(fund: late, period: Date.new(2026, 3, 31))
    report(fund: late, at: current.filing.filed_at + 1.second, positions: [ { shares: 150 } ])
    _bad_prior, bad_current = pair(fund: create(:institutional_filer))
    bad_current.update!(table_entry_total: 2)
    _failed_prior, failed_current = pair(fund: create(:institutional_filer))
    failed_current.filing.update!(parse_status: "failed")
    expect(measured.fetch("corroborating_activity").fetch(:inputs)).to include("participant_count" => 1)
  end

  it "requires a resolvable original for restatements used as comparison sources" do
    report(period: Date.new(2026, 3, 31))
    current = report(amendment_type: "RESTATEMENT", positions: [ { shares: 150 } ])
    result = assessment
    expect(result).to include(status: "ineligible", eligibility_reason: "incomplete_report_context")
    expect(result.fetch(:source_coverage).fetch(:invalid_report_ids)).to eq([ current.id ])
  end

  it "flags count/value mismatches, suspect reports and invalid rows without modifying them" do
    previous, current = pair
    row = row_for
    [ { table_entry_total: 2 }, { table_value_total: 1 }, { suspect: true }, { table_entry_total: nil }, { table_value_total: nil } ].each do |attributes|
      current.update!(table_entry_total: 1, table_value_total: 1500, suspect: false, **attributes)
      result = assessment(row:)
      expect(result).to include(status: "ineligible", score: nil)
      expect(result.fetch(:source_coverage).fetch(:invalid_report_ids)).to eq([ current.id ])
    end
    current.update!(table_entry_total: 1, table_value_total: 1500)
    holding = current.institutional_holdings.sole
    [ { shares: -1 }, { shares: BigDecimal("NaN") }, { suspect: true }, { cusip: "INVALID" } ].each do |attributes|
      holding.update!(shares: 150, suspect: false, cusip:, **attributes)
      expect(assessment(row:)).to include(status: "ineligible", score: nil)
    end
    expect(holding.reload.cusip).to eq("INVALID")
    expect(previous.reload.institutional_holdings.sole.shares).to eq(100)
  end

  it "keeps unknown value normalization separate from complete share coverage" do
    pair(after: 150, value_usd: nil)
    result = assessment
    expect(result).to include(status: "incomplete", score: nil)
    expect(result.fetch(:source_coverage)).to include(reports_complete: true, values_complete: false)
    expect(result.fetch(:coverage)).to include(available_weight: 50)
    expect(measured(result).fetch("own_history")).to include(status: "unavailable", unavailable_reason: "unusable_reported_value_change")
    expect(measured(result).fetch("position_size_change")).to include(value: BigDecimal("0.5"))
  end

  it "checks normalized unit multipliers without changing reported thousands" do
    previous, current = pair(after: 150, value_unit: "thousands")
    [ previous, current ].each { |item| item.update!(cover_value_unit: "thousands") }
    expect(assessment.fetch(:source_coverage)).to include(reports_complete: true, values_complete: true)
    current.institutional_holdings.sole.update!(value_usd: 1500)
    expect(assessment.fetch(:source_coverage)).to include(reports_complete: true, values_complete: false)
    expect(current.institutional_holdings.sole.reload.value_reported).to eq(1500)
    current.update!(cover_value_unit: nil)
    expect(assessment.fetch(:source_coverage)).to include(values_complete: false)
  end

  [ { before: nil }, { after: nil } ].each do |positions|
    it "uses complete empty reports for #{positions.key?(:before) ? 'new positions' : 'full exits'}" do
      pair(**positions)
      expect(measured.fetch("position_size_change")).to include(value: 1, status: "available")
      expect(measured.fetch("reported_context")).to include(value: 1)
    end
  end

  it "measures reductions, caps large increases, and holds short histories unavailable" do
    previous, current = pair(after: 75)
    expect(measured.fetch("position_size_change")).to include(value: BigDecimal("0.25"))
    expect(measured.fetch("own_history")).to include(status: "unavailable", unavailable_reason: "insufficient_history")
    expect(measured.fetch("own_history").fetch(:inputs)).to include("history_count" => 0)
    current.institutional_holdings.sole.update!(shares: 300, value_reported: 3000, value_usd: 3000)
    current.update!(table_value_total: 3000)
    expect(measured.fetch("position_size_change")).to include(value: 1)
    expect(previous.institutional_holdings.sole.shares).to eq(100)
  end

  it "uses Eastern calendar-day period age and caps the penalty without claiming a legal deadline" do
    previous = report(period: Date.new(2026, 3, 31), at: Time.utc(2026, 6, 1))
    current = report(at: Time.utc(2026, 7, 1, 2), positions: [ { shares: 150 } ])
    expect(measured.fetch("lateness")).to include(value: 0, points: 0)
    current.filing.update!(filed_at: Time.utc(2026, 10, 1, 20))
    expect(measured.fetch("lateness")).to include(value: 1, points: -15)
    current.filing.update!(filed_at: Time.utc(2026, 6, 30, 2))
    expect(measured.fetch("lateness")).to include(status: "unavailable", unavailable_reason: "future_report_period")
    expect(previous.reload.status).to eq("parsed")
  end

  it "does not treat a report truncated by the request's holding ID bound as complete" do
    previous, current = pair
    row = row_for
    bounds = { "filings" => Filing.maximum(:id), "reports" => InstitutionalReport.maximum(:id),
               "holdings" => previous.institutional_holdings.sole.id }
    result = described_class.new(row:, bounds:).call
    expect(result).to include(status: "ineligible", score: nil)
    expect(result.fetch(:source_coverage).fetch(:invalid_report_ids)).to eq([ current.id ])
  end
end
