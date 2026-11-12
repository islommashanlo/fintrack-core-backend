# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Fund position history" do
  include InstitutionalReadHelpers
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }
  let(:fund) { create(:institutional_filer) }
  let(:key) { "037833100" }
  let(:period) { Date.new(2026, 6, 30) }

  def report(period: self.period, rows: [ {} ], **attributes)
    item = create_13f(fund:, period:, **attributes)
    holdings = rows.map do |row|
      value = row.fetch(:value_reported, 100)
      create(:institutional_holding, institutional_report: item, value_reported: value, value_usd: value, **row)
    end
    item.update!(table_entry_total: holdings.length, table_value_total: holdings.sum(&:value_reported))
    item
  end

  def path(filer = fund)
    position_history_api_v1_fund_path(filer.cik)
  end

  def fetch(**parameters)
    get path, params: { cusip: key, **parameters }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    response.parsed_body
  end

  it "returns reported shares, full-portfolio weights and source provenance for observed quarters" do
    old = report(period: Date.new(2026, 3, 31), rows: [ {}, { cusip: "594918104", value_reported: 300 } ])
    latest = report(rows: [ { shares: 20, value_reported: 200 }, { cusip: "594918104", value_reported: 300 } ])
    body = fetch(sort: "period")
    expect(body.fetch("data").pluck("period_of_report")).to eq([ "2026-03-31", "2026-06-30" ])
    row = body.fetch("data").last
    expect(row).to include("accession" => latest.filing.accession_no, "sec_url" => latest.filing.sec_url,
      "status" => "reported", "cusip" => key, "put_call" => nil, "share_type" => "SH", "data_age_days" => 90)
    expect(row.fetch("position")).to include("shares_reported" => "20.0", "value_usd" => "200.0", "rank" => 2, "row_count" => 1)
    expect(BigDecimal(row.dig("position", "weight_percent"))).to eq(40)
    expect(row.dig("portfolio", "total_value_usd")).to eq("500.0")
    expect(row.fetch("sources").pluck("accession")).to eq([ latest.filing.accession_no ])
    expect(body.fetch("data").first.fetch("sources").pluck("accession")).to eq([ old.filing.accession_no ])
    expect(body.fetch("meta")).to include("total_count" => 2, "missing_periods_filled" => false, "disclaimer" => FilingsIntel::DISCLAIMER)
  end

  it "distinguishes complete absence from unknown notice and unresolved amendment coverage without filling quarters" do
    empty = report(period: Date.new(2025, 12, 31), rows: [])
    notice = report(period: Date.new(2026, 6, 30), submission_type: "13F-NT", report_type: "13F NOTICE", rows: [])
    addition = report(period: Date.new(2026, 9, 30), amendment_type: "NEW HOLDINGS")
    rows = fetch(sort: "period").fetch("data")
    expect(rows.pluck("period_of_report")).to eq([ "2025-12-31", "2026-06-30", "2026-09-30" ])
    expect(rows.pluck("status")).to eq(%w[not_reported unknown unknown])
    expect(rows.pluck("position")).to eq([ nil, nil, nil ])
    expect(rows.first.fetch("portfolio")).to include("complete" => true, "total_value_usd" => "0.0", "report_ids" => [ empty.id ])
    expect(rows.last.fetch("portfolio")).to include("complete" => false, "total_value_usd" => nil, "report_ids" => [])
    expect(rows.last(2).pluck("accession")).to eq([ notice.filing.accession_no, addition.filing.accession_no ])
  end

  it "groups restated and additive rows and separates options and principal keys" do
    report
    base = report(amendment_type: "RESTATEMENT", filed_at: Time.utc(2026, 8, 15),
      rows: [ { shares: 20 }, { put_call: "PUT", shares: 5, value_reported: 50 }, { share_type: "PRN", value_reported: 100 } ])
    added = report(amendment_type: "NEW HOLDINGS", filed_at: Time.utc(2026, 8, 16), rows: [ { shares: 10, value_reported: 50 } ])
    row = fetch.fetch("data").sole
    expect(row.fetch("position")).to include("row_count" => 2, "shares_reported" => "30.0", "value_usd" => "150.0", "rank" => 1)
    expect(BigDecimal(row.dig("position", "weight_percent"))).to eq(50)
    expect(row.dig("portfolio", "report_ids")).to eq([ base.id, added.id ])
    expect(row.fetch("sources").pluck("accession")).to eq([ added.filing.accession_no, base.filing.accession_no ])
    expect(fetch(put_call: "PUT").dig("data", 0, "position", "shares_reported")).to eq("5.0")
    expect(fetch(share_type: "PRN").dig("data", 0, "position", "value_usd")).to eq("100.0")
  end

  it "preserves known observations while withholding all ranks and weights for incomplete portfolios" do
    bad = report(rows: [ {}, { cusip: "594918104", value_usd: nil } ])
    row = fetch.fetch("data").sole
    expect(row).to include("status" => "reported")
    expect(row.fetch("position")).to include("value_usd" => "100.0", "rank" => nil, "weight_percent" => nil)
    expect(row.fetch("portfolio")).to include("complete" => false, "known_value_usd" => "100.0", "total_value_usd" => nil,
      "incomplete_report_ids" => [ bad.id ])
    other = fetch(cusip: "02079K305").fetch("data").sole
    expect(other).to include("status" => "unknown", "position" => nil)
  end

  it "uses historic normalized values and keeps zero weights distinct from missing data" do
    old = report(period: Date.new(2025, 12, 31), cover_value_unit: "thousands",
      rows: [ { value_reported: BigDecimal("1.25"), value_unit: "thousands", value_usd: 1250 } ])
    report(rows: [ { value_reported: 0 } ])
    rows = fetch(sort: "period").fetch("data")
    expect(rows.first.dig("position", "value_usd")).to eq("1250.0")
    expect(rows.first.dig("portfolio", "complete")).to be(true)
    expect(rows.last.fetch("position")).to include("value_usd" => "0.0", "rank" => 1, "weight_percent" => nil)
    expect(old.institutional_holdings.sole.value_reported).to eq(BigDecimal("1.25"))
  end

  it "pins all periods and portfolio evidence across cursor continuation" do
    older = report(period: Date.new(2026, 3, 31))
    latest = report
    first = fetch(limit: 1)
    report(period: older.period_of_report, amendment_type: "RESTATEMENT", filed_at: Time.current, rows: [ { shares: 999 } ])
    report(period: Date.new(2026, 9, 30))
    create(:institutional_holding, institutional_report: older, shares: 999)
    second = fetch(limit: 1, cursor: first.dig("meta", "next_cursor"))
    expect(second.fetch("data").sole.fetch("accession")).to eq(older.filing.accession_no)
    expect(second.dig("data", 0, "position", "shares_reported")).to eq("10.0")
    expect(second.dig("data", 0, "portfolio", "complete")).to be(true)
    expect(second.fetch("meta")).to include("total_count" => 2, "has_more" => false)
    expect(first.fetch("data").sole.fetch("accession")).to eq(latest.filing.accession_no)
    get path, params: { cusip: "594918104", limit: 1, cursor: first.dig("meta", "next_cursor") }
    expect(response).to have_http_status(:bad_request)
  end

  it "previews Free history, rejects older selected quarters and supports exact period selection" do
    report(period: Date.new(2025, 9, 30))
    allowed = report(period: Date.new(2025, 12, 31))
    report
    body = fetch
    expect(body.fetch("data").pluck("period_of_report")).to eq([ "2026-06-30", "2025-12-31" ])
    expect(body.fetch("meta")).to include("total_count" => 3, "accessible_count" => 2, "truncated" => true, "feature" => "history_quarters", "history_quarters" => 4)
    expect(fetch(period: "2025-12-31").fetch("data").sole.fetch("accession")).to eq(allowed.filing.accession_no)
    get path, params: { cusip: key, period: "2025-09-30" }
    expect(response).to have_http_status(:payment_required)
  end

  it "allows verified Pro full history and rejects continuation after entitlement changes" do
    with_billing_config do
      report(period: Date.new(2025, 9, 30))
      report
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      body = fetch(limit: 1)
      expect(body.fetch("meta")).to include("history_quarters" => nil, "truncated" => false, "total_count" => 2)
      apply_billing_event(id: "evt_position_history_canceled", snapshot: billing_snapshot(status: "canceled"), type: "customer.subscription.deleted")
      get path, params: { cusip: key, limit: 1, cursor: body.dig("meta", "next_cursor") }
      expect(response).to have_http_status(:bad_request)
    end
  end

  it "scopes cursor continuation to its fund and actor" do
    report(period: Date.new(2026, 3, 31))
    report
    cursor = fetch(limit: 1).dig("meta", "next_cursor")
    get path(create(:institutional_filer)), params: { cusip: key, limit: 1, cursor: }
    expect(response).to have_http_status(:bad_request)
    api_login(create(:user, password: "password123"))
    get path, params: { cusip: key, limit: 1, cursor: }
    expect(response).to have_http_status(:bad_request)
  end

  it "ignores other funds, future filings and failed reports and returns empty history without source data" do
    expect(fetch.fetch("data")).to eq([])
    wanted = report
    report(period: Date.new(2026, 9, 30), filed_at: 1.day.from_now)
    failed = report(period: Date.new(2026, 3, 31))
    failed.filing.update!(parse_status: "failed")
    create_13f(fund: create(:institutional_filer), period: Date.new(2026, 9, 30))
    expect(fetch.fetch("data").pluck("accession")).to eq([ wanted.filing.accession_no ])
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "rejects malformed keys, periods, sorts, cursors and unknown parameters" do
    [ {}, { cusip: "bad" }, { cusip: key, put_call: "ALL" }, { cusip: key, share_type: "STOCK" },
      { cusip: key, period: "2026-06-01" }, { cusip: key, sort: "rank" }, { cusip: key, limit: 101 },
      { cusip: key, cursor: "invalid" }, { cusip: key, unexpected: "true" } ].each do |parameters|
      get path, params: parameters
      expect(response).to have_http_status(:bad_request), parameters.inspect
    end
    get position_history_api_v1_fund_path("0000000001"), params: { cusip: key }
    expect(response).to have_http_status(:not_found)
  end
end
