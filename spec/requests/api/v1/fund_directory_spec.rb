# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reported fund directory metrics" do
  include OpenapiResponses
  include InstitutionalReadHelpers
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }

  def report(fund:, period: Date.new(2026, 6, 30), rows: [ {} ], **attributes)
    item = create_13f(fund:, period:, **attributes)
    holdings = rows.map do |row|
      value = row.fetch(:value_reported, 100)
      create(:institutional_holding, institutional_report: item, value_reported: value, value_usd: value, **row)
    end
    item.update!(table_entry_total: holdings.length, table_value_total: holdings.sum(&:value_reported))
    item
  end

  def fetch(**parameters)
    get api_v1_funds_path, params: parameters
    expect_documented_response(path: "/funds")
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    response.parsed_body
  end

  it "filters complete reported values and grouped positions while preserving source evidence" do
    fund = create(:institutional_filer, name: "Known Fund")
    source = report(fund:, rows: [ { value_reported: 100 }, { value_reported: 50 }, { put_call: "PUT", value_reported: 25 },
      { share_type: "PRN", value_reported: 25 } ])
    report(fund: create(:institutional_filer, name: "Smaller"), rows: [ { value_reported: 50 } ])
    body = fetch(min_portfolio_value_usd: "200", max_portfolio_value_usd: "200.00", min_position_count: "3", max_position_count: "3")
    expect(body.fetch("data").pluck("cik")).to eq([ fund.cik ])
    row = body.fetch("data").sole.fetch("reported_portfolio")
    expect(row).to include("value_usd" => "200.0", "position_count" => 3, "holding_row_count" => 4, "complete" => true,
      "accession" => source.filing.accession_no, "period_of_report" => "2026-06-30", "effective_report_count" => 1)
    expect(row.fetch("sources").pluck("accession")).to eq([ source.filing.accession_no ])
    expect(body.fetch("meta")).to include("value_is_aum" => false, "portfolio_period" => "latest_per_fund")
  end

  it "resolves restatements/additions and preserves known zero versus missing/flagged values" do
    fund = create(:institutional_filer)
    report(fund:, rows: [ { value_reported: 999 } ])
    base = report(fund:, amendment_type: "RESTATEMENT", filed_at: Time.utc(2026, 8, 15), rows: [ { value_reported: 0 } ])
    addition = report(fund:, amendment_type: "NEW HOLDINGS", filed_at: Time.utc(2026, 8, 16), rows: [ { value_reported: 0 } ])
    unknown = create(:institutional_filer)
    report(fund: unknown, rows: [ { value_usd: nil } ])
    flagged = create(:institutional_filer)
    report(fund: flagged, suspect: true)
    body = fetch(min_portfolio_value_usd: "0", max_portfolio_value_usd: "0")
    row = body.fetch("data").sole
    expect(row.fetch("cik")).to eq(fund.cik)
    expect(row.fetch("reported_portfolio")).to include("value_usd" => "0.0", "position_count" => 1, "effective_report_count" => 2)
    expect(row.dig("reported_portfolio", "sources").pluck("accession")).to eq([ addition.filing.accession_no, base.filing.accession_no ])
    incomplete = fetch.fetch("data").find { |item| item["cik"] == unknown.cik }
    expect(incomplete.fetch("portfolio_unavailable_reason")).to eq("incomplete_report_set")
    expect(incomplete.fetch("reported_portfolio")).to include("value_usd" => nil, "position_count" => nil, "complete" => false)
  end

  it "treats latest notices and unresolved additions as unavailable instead of falling back to older holdings" do
    fund = create(:institutional_filer)
    report(fund:)
    notice = report(fund:, period: Date.new(2026, 9, 30), submission_type: "13F-NT", report_type: "13F NOTICE", rows: [])
    orphan = create(:institutional_filer)
    report(fund: orphan, amendment_type: "NEW HOLDINGS")
    rows = fetch.fetch("data")
    expect(rows.map { |row| row.fetch("portfolio_unavailable_reason") }).to eq([ "no_effective_holdings", "no_effective_holdings" ])
    row = rows.find { |item| item["cik"] == fund.cik }.fetch("reported_portfolio")
    expect(row).to include("complete" => false, "value_usd" => nil, "effective_report_count" => 0, "accession" => notice.filing.accession_no)
    expect(fetch(min_position_count: "0").fetch("data")).to eq([])
  end

  it "sorts known values through stable ties then nulls, pinned across new holdings and amendments" do
    a, b, unknown = 3.times.map { create(:institutional_filer, name: "Same Name") }
    first = report(fund: a)
    report(fund: b)
    body = fetch(sort: "-portfolio_value_usd", limit: 1)
    expect(body.fetch("data").sole.fetch("cik")).to eq(b.cik)
    report(fund: a, amendment_type: "RESTATEMENT", filed_at: Time.current, rows: [ { value_reported: 999 } ])
    create(:institutional_holding, institutional_report: first, value_reported: 999)
    create(:institutional_filer)
    second = fetch(sort: "-portfolio_value_usd", limit: 1, cursor: body.dig("meta", "next_cursor"))
    expect(second.fetch("data").sole.fetch("cik")).to eq(a.cik)
    expect(second.dig("data", 0, "reported_portfolio", "value_usd")).to eq("100.0")
    third = fetch(sort: "-portfolio_value_usd", limit: 1, cursor: second.dig("meta", "next_cursor"))
    expect(third.fetch("data").sole.fetch("cik")).to eq(unknown.cik)
    expect(third.fetch("meta")).to include("total_count" => 3, "has_more" => false)
  end

  it "supports exact quarter selection and historic thousands without market-data assumptions" do
    fund = create(:institutional_filer)
    source = report(fund:, period: Date.new(2026, 3, 31), cover_value_unit: "thousands",
      rows: [ { value_reported: BigDecimal("1.25"), value_unit: "thousands", value_usd: 1250 } ])
    report(fund:, rows: [ { value_reported: 10 } ])
    row = fetch(period: "2026-03-31", min_portfolio_value_usd: "1250").fetch("data").sole.fetch("reported_portfolio")
    expect(row).to include("value_usd" => "1250.0", "accession" => source.filing.accession_no)
  end

  it "hides default older metrics for Free while retaining identity and rejects explicit older quarters" do
    fund = create(:institutional_filer)
    report(fund:, period: Date.new(2025, 9, 30))
    row = fetch.fetch("data").sole
    expect(row).to include("cik" => fund.cik, "reported_portfolio" => nil, "portfolio_unavailable_reason" => "history_restricted")
    expect(fetch(min_portfolio_value_usd: "0").fetch("data")).to eq([])
    get api_v1_funds_path, params: { period: "2025-09-30" }
    expect_documented_response(path: "/funds")
    expect(response).to have_http_status(:payment_required)
  end

  it "allows verified Pro older values and invalidates cursors on entitlement or actor changes" do
    with_billing_config do
      fund = create(:institutional_filer)
      report(fund:, period: Date.new(2025, 9, 30))
      create(:institutional_filer)
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      body = fetch(period: "2025-09-30", sort: "-portfolio_value_usd", limit: 1)
      expect(body.dig("data", 0, "reported_portfolio", "value_usd")).to eq("100.0")
      apply_billing_event(id: "evt_fund_directory_canceled", snapshot: billing_snapshot(status: "canceled"), type: "customer.subscription.deleted")
      get api_v1_funds_path, params: { period: "2025-09-30", sort: "-portfolio_value_usd", limit: 1, cursor: body.dig("meta", "next_cursor") }
      expect_documented_response(path: "/funds")
      expect(response).to have_http_status(:bad_request)
    end
  end

  it "sorts position counts, preserves valid empty reports and excludes future or failed sources" do
    one, two, empty, unknown = 4.times.map { create(:institutional_filer) }
    wanted = report(fund: one)
    report(fund: one, period: Date.new(2026, 9, 30), filed_at: 1.day.from_now, rows: [ { value_reported: 999 } ])
    failed = report(fund: one, period: Date.new(2026, 9, 30))
    failed.filing.update!(parse_status: "failed")
    report(fund: two, rows: [ {}, { cusip: "594918104" } ])
    report(fund: empty, rows: [])
    rows = fetch(sort: "-position_count").fetch("data")
    expect(rows.pluck("cik")).to eq([ two.cik, one.cik, empty.cik, unknown.cik ])
    expect(rows.find { |row| row["cik"] == one.cik }.dig("reported_portfolio", "accession")).to eq(wanted.filing.accession_no)
    zero = fetch(max_position_count: "0").fetch("data").sole
    expect(zero.fetch("cik")).to eq(empty.cik)
    expect(zero.fetch("reported_portfolio")).to include("complete" => true, "value_usd" => "0.0", "position_count" => 0)
  end

  it "rejects malformed ranges, unsupported fields, periods and incompatible cursors" do
    [ { min_portfolio_value_usd: "NaN" }, { max_portfolio_value_usd: "1e3" }, { min_position_count: "1.5" },
      { min_position_count: "-1" }, { min_portfolio_value_usd: "2", max_portfolio_value_usd: "1" },
      { min_position_count: "2", max_position_count: "1" }, { aum: "100" }, { period: "2026-06-01" }, { sort: "aum" } ].each do |parameters|
      get api_v1_funds_path, params: parameters
      expect_documented_response(path: "/funds")
      expect(response).to have_http_status(:bad_request), parameters.inspect
    end
    2.times { create(:institutional_filer) }
    body = fetch(limit: 1)
    get api_v1_funds_path, params: { limit: 1, min_position_count: "0", cursor: body.dig("meta", "next_cursor") }
    expect_documented_response(path: "/funds")
    expect(response).to have_http_status(:bad_request)
    api_login(create(:user, password: "password123"))
    get api_v1_funds_path, params: { limit: 1, cursor: body.dig("meta", "next_cursor") }
    expect_documented_response(path: "/funds")
    expect(response).to have_http_status(:bad_request)
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
