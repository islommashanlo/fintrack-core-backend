# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reported fund allocation turnover" do
  include OpenapiResponses
  include InstitutionalReadHelpers
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }
  let(:fund) { create(:institutional_filer) }
  let(:current) { Date.new(2026, 9, 30) }
  let(:prior) { Date.new(2026, 6, 30) }

  def report(quarter: current, rows: [ {} ], **attributes)
    item = create_13f(fund:, period: quarter, filed_at: quarter == current ? 2.days.ago : Time.utc(2026, 8, 14), **attributes)
    holdings = rows.map do |row|
      value = row.fetch(:value_reported, 100)
      create(:institutional_holding, institutional_report: item, value_reported: value, value_usd: value, **row)
    end
    item.update!(table_entry_total: holdings.length, table_value_total: holdings.sum(&:value_reported))
    item
  end

  def fetch(**parameters)
    get turnover_api_v1_fund_path(fund.cik), params: parameters
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/funds/{cik}/turnover")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    response.parsed_body
  end

  def data(**parameters) = fetch(**parameters).fetch("data")
  def metric(body) = BigDecimal(body.fetch("reported_allocation_turnover_percent"))

  it "measures the full adjacent-quarter allocation change with exact decimals and source evidence" do
    before = report(quarter: prior, rows: [ { value_reported: 25 }, { cusip: "594918104", value_reported: 75 } ])
    after = report(rows: [ { value_reported: 50 }, { cusip: "594918104", value_reported: 50 } ])
    body = fetch
    result = body.fetch("data")
    expect(metric(result)).to eq(25)
    expect(result).to include("period_of_report" => current.iso8601, "prior_period_of_report" => prior.iso8601,
      "status" => "available", "unavailable_reason" => nil, "accession" => after.filing.accession_no,
      "sec_url" => after.filing.sec_url, "filed_at" => after.filing.filed_at.as_json)
    expect(result.dig("current_portfolio", "sources").pluck("accession")).to eq([ after.filing.accession_no ])
    expect(result.dig("prior_portfolio", "sources").pluck("accession")).to eq([ before.filing.accession_no ])
    expect(result.dig("current_portfolio", "total_value_usd")).to eq("100.0")
    expect(body.fetch("meta")).to include("period_selection" => "latest_report", "baseline_policy" => "adjacent_calendar_quarter",
      "methodology_version" => "reported-allocation-turnover-v1", "history_quarters" => 4,
      "disclaimer" => FilingsIntel::DISCLAIMER)
    expect(fetch(period: current.iso8601).dig("meta", "period_selection")).to eq("explicit")
  end

  it "returns zero for unchanged weights despite different reported values and one hundred for disjoint keys" do
    report(quarter: prior, rows: [ { value_reported: BigDecimal("0.01") }, { cusip: "594918104", value_reported: BigDecimal("0.02") } ])
    after = report(rows: [ { value_reported: BigDecimal("0.02") }, { cusip: "594918104", value_reported: BigDecimal("0.04") } ])
    expect(metric(data)).to eq(0)
    after.institutional_holdings.update_all(cusip: "02079K305")
    expect(metric(data)).to eq(100)
  end

  it "includes new and exited keys and keeps put/call and principal separate while grouping repeated rows" do
    report(quarter: prior, rows: [ { value_reported: 40 }, { value_reported: 10 },
      { put_call: "PUT", value_reported: 25 }, { share_type: "PRN", value_reported: 25 } ])
    report(rows: [ { value_reported: 25 }, { put_call: "CALL", value_reported: 25 },
      { cusip: "594918104", value_reported: 25 }, { share_type: "PRN", value_reported: 25 } ])
    result = data
    expect(metric(result)).to eq(50)
    expect(result.dig("prior_portfolio", "holding_row_count")).to eq(4)
    expect(result.dig("prior_portfolio", "position_count")).to eq(3)
  end

  it "uses independent restatements and additions without including superseded or unrelated holdings" do
    report(quarter: prior, rows: [ { value_reported: 999 } ])
    before = report(quarter: prior, amendment_type: "RESTATEMENT", filed_at: Time.utc(2026, 8, 15),
      rows: [ { value_reported: 50 }, { cusip: "594918104", value_reported: 50 } ])
    report(rows: [ { value_reported: 999 } ])
    base = report(amendment_type: "RESTATEMENT", filed_at: 1.day.ago, rows: [ { value_reported: 50 } ])
    addition = report(amendment_type: "NEW HOLDINGS", filed_at: 1.hour.ago, rows: [ { cusip: "594918104", value_reported: 50 } ])
    create(:institutional_holding, institutional_report: create_13f(fund: create(:institutional_filer)))
    result = data
    expect(metric(result)).to eq(0)
    expect(result.dig("current_portfolio", "report_ids")).to eq([ base.id, addition.id ])
    expect(result.dig("prior_portfolio", "report_ids")).to eq([ before.id ])
    expect(result.fetch("accession")).to eq(addition.filing.accession_no)
  end

  it "withholds the metric for incomplete values, invalid cover totals and unresolved originals on either side" do
    before = report(quarter: prior)
    after = report
    holding = after.institutional_holdings.sole
    holding.update!(value_usd: nil)
    expect(data).to include("status" => "unavailable", "unavailable_reason" => "incomplete_current_portfolio",
      "reported_allocation_turnover_percent" => nil)
    holding.update!(value_usd: 1000)
    expect(data.fetch("unavailable_reason")).to eq("incomplete_current_portfolio")
    holding.update!(value_usd: 100)
    after.update!(table_entry_total: 2)
    expect(data.fetch("unavailable_reason")).to eq("incomplete_current_portfolio")
    after.update!(table_entry_total: 1)
    before.update!(suspect: true)
    expect(data.fetch("unavailable_reason")).to eq("incomplete_prior_portfolio")
    before.update!(suspect: false)
    after.update!(submission_type: "13F-HR/A", amendment_type: "RESTATEMENT")
    after.filing.update!(form_type: "13F-HR/A")
    expect(data.fetch("unavailable_reason")).to eq("incomplete_current_portfolio")
  end

  it "distinguishes empty or zero-value portfolios from unchanged weights" do
    before = report(quarter: prior)
    after = report(rows: [])
    result = data
    expect(result).to include("reported_allocation_turnover_percent" => nil, "unavailable_reason" => "zero_current_portfolio_value")
    expect(result.fetch("current_portfolio")).to include("complete" => true, "total_value_usd" => "0.0")
    create(:institutional_holding, institutional_report: after, value_reported: 0, value_usd: 0)
    after.update!(table_entry_total: 1)
    expect(data.fetch("unavailable_reason")).to eq("zero_current_portfolio_value")
    after.institutional_holdings.sole.update!(value_reported: 100, value_usd: 100)
    after.update!(table_value_total: 100)
    before.institutional_holdings.sole.update!(value_reported: 0, value_usd: 0)
    before.update!(table_value_total: 0)
    expect(data.fetch("unavailable_reason")).to eq("zero_prior_portfolio_value")
  end

  it "uses the adjacent quarter only and does not fall back from a latest notice" do
    report(quarter: Date.new(2026, 3, 31))
    base = report
    result = data
    expect(result).to include("unavailable_reason" => "no_prior_report", "reported_allocation_turnover_percent" => nil)
    expect(result.dig("prior_portfolio", "sources")).to eq([])
    report(quarter: prior)
    base.filing.update!(parse_status: "failed")
    notice = report(submission_type: "13F-NT", report_type: "13F NOTICE", rows: [])
    result = data
    expect(result).to include("period_of_report" => current.iso8601, "unavailable_reason" => "no_effective_current_holdings")
    expect(result.fetch("current_portfolio")).to include("source_scope" => "observed_reports", "report_ids" => [])
    expect(result.dig("current_portfolio", "sources").pluck("accession")).to eq([ notice.filing.accession_no ])
  end

  it "reports absent data explicitly and excludes failed, future and unparsed reports" do
    expect(data).to include("period_of_report" => nil, "unavailable_reason" => "no_current_report")
    report(quarter: prior)
    expect(data(period: current.iso8601).fetch("unavailable_reason")).to eq("no_current_report")
    report(filed_at: 1.day.from_now)
    failed = report
    failed.filing.update!(parse_status: "failed")
    report(status: "pending")
    expect(data(period: current.iso8601).fetch("unavailable_reason")).to eq("no_current_report")
  end

  it "withholds future report periods and records prior notices as observed evidence" do
    report(quarter: prior, submission_type: "13F-NT", report_type: "13F NOTICE", rows: [])
    report
    expect(data.fetch("unavailable_reason")).to eq("no_effective_prior_holdings")
    report(quarter: Date.new(2026, 12, 31))
    result = data
    expect(result).to include("unavailable_reason" => "future_report_period", "reported_allocation_turnover_percent" => nil)
  end

  it "normalizes thousands separately and explains the implemented methodology" do
    report(quarter: prior, cover_value_unit: "thousands", rows: [ { value_reported: BigDecimal("0.1"), value_unit: "thousands", value_usd: 100 } ])
    report(rows: [ { value_reported: 100 } ])
    expect(metric(data)).to eq(0)
    get api_v1_methodology_path
    expect_documented_response(path: "/methodology")
    expect(response.parsed_body.dig("data", "reported_allocation_turnover")).to include("status" => "available",
      "version" => "reported-allocation-turnover-v1", "security_key" => %w[cusip put_call share_type])
  end

  it "pins source ID ceilings before late holdings and restatements arrive" do
    report(quarter: prior)
    base = report
    query = Api::V1::FundTurnoverQuery.new(fund:, history: Api::V1::HistoryWindow.new(limit: 4), as_of: Time.current)
    report(amendment_type: "RESTATEMENT", filed_at: Time.current, rows: [ { cusip: "594918104" } ])
    create(:institutional_holding, institutional_report: base, value_reported: 999)
    result = query.call.fetch(:data)
    expect(result.fetch(:reported_allocation_turnover_percent)).to eq(0)
    expect(result.fetch(:current_portfolio).fetch("report_ids")).to eq([ base.id ])
  end

  it "gates old current periods while allowing an adjacent baseline outside the Free window" do
    report(quarter: Date.new(2025, 9, 30))
    report(quarter: Date.new(2025, 12, 31))
    expect(metric(data(period: "2025-12-31"))).to eq(0)
    get turnover_api_v1_fund_path(fund.cik), params: { period: "2025-09-30" }
    expect_documented_response(path: "/funds/{cik}/turnover")
    expect(response).to have_http_status(:payment_required)
    expect(response.parsed_body).to eq("code" => "PRO_REQUIRED", "feature" => "history_quarters", "limit" => 4)
    with_billing_config do
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      expect(data(period: "2025-09-30").fetch("unavailable_reason")).to eq("no_prior_report")
    end
  end

  it "rejects malformed periods, unsupported filters and unknown funds without writes or HTTP" do
    counts = [ Filing.count, InstitutionalReport.count, InstitutionalHolding.count ]
    [ { period: "2026-09-29" }, { period: "not-a-date" }, { period: [] }, { cursor: "opaque" }, { cusip: "037833100" } ].each do |parameters|
      get turnover_api_v1_fund_path(fund.cik), params: parameters
      expect_documented_response(path: "/funds/{cik}/turnover")
      expect(response).to have_http_status(:bad_request)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
    get turnover_api_v1_fund_path("0000000001")
    expect_documented_response(path: "/funds/{cik}/turnover")
    expect(response).to have_http_status(:not_found)
    expect([ Filing.count, InstitutionalReport.count, InstitutionalHolding.count ]).to eq(counts)
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
