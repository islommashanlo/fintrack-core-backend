# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reported portfolio summaries on fund profiles" do
  include InstitutionalReadHelpers
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }
  let(:fund) { create(:institutional_filer) }

  def report(rows: [ {} ], **attributes)
    item = create_13f(fund:, **attributes)
    holdings = rows.map do |row|
      value = row.fetch(:value_reported, 100)
      create(:institutional_holding, institutional_report: item, value_reported: value, value_usd: value, **row)
    end
    item.update!(table_entry_total: holdings.length, table_value_total: holdings.sum(&:value_reported))
    item
  end

  def profile
    get api_v1_fund_path(fund.cik)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    response.parsed_body
  end

  def directory_row
    get api_v1_funds_path, params: { q: fund.cik }
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("data").sole
  end

  it "reuses the directory portfolio contract while preserving the latest raw cover metadata" do
    base = report(rows: [ { value_reported: 100 }, { value_reported: 50 } ])
    addition = report(amendment_type: "NEW HOLDINGS", filed_at: Time.utc(2026, 8, 15), report_type: "13F COMBINATION REPORT",
      rows: [ { put_call: "PUT", value_reported: 25 } ])
    body = profile
    data = body.fetch("data")
    expect(data.slice("reported_portfolio", "portfolio_unavailable_reason")).to eq(directory_row.slice("reported_portfolio", "portfolio_unavailable_reason"))
    expect(data.fetch("reported_portfolio")).to include("complete" => true, "value_usd" => "175.0", "position_count" => 2,
      "holding_row_count" => 3, "effective_report_count" => 2)
    expect(data.dig("reported_portfolio", "sources").pluck("accession")).to eq([ addition.filing.accession_no, base.filing.accession_no ])
    expect(data.fetch("latest_report")).to include("accession" => addition.filing.accession_no, "table_value_total" => "25.0", "table_entry_total" => 1,
      "report_type" => "13F COMBINATION REPORT")
    expect(body.fetch("meta")).to include("history_quarters" => 4, "portfolio_period" => "latest_per_fund", "value_is_aum" => false,
      "disclaimer" => FilingsIntel::DISCLAIMER)
  end

  it "keeps suspect and missing normalized values unknown without changing raw cover totals" do
    item = report(rows: [ { value_usd: nil } ])
    data = profile.fetch("data")
    expect(data.fetch("reported_portfolio")).to include("complete" => false, "value_usd" => nil, "position_count" => nil)
    expect(data.fetch("portfolio_unavailable_reason")).to eq("incomplete_report_set")
    expect(data.fetch("latest_report")).to include("table_value_total" => "100.0", "accession" => item.filing.accession_no)
    item.update!(suspect: true)
    expect(profile.dig("data", "reported_portfolio", "complete")).to be(false)
  end

  it "preserves known empty reports as zero and excludes superseded, future and failed sources" do
    report(rows: [ { value_reported: 999 } ])
    replacement = report(amendment_type: "RESTATEMENT", filed_at: Time.utc(2026, 8, 15), rows: [])
    report(period: Date.new(2026, 9, 30), filed_at: 1.day.from_now)
    failed = report(period: Date.new(2026, 9, 30))
    failed.filing.update!(parse_status: "failed")
    data = profile.fetch("data")
    expect(data.fetch("reported_portfolio")).to include("value_usd" => "0.0", "position_count" => 0, "complete" => true,
      "effective_report_count" => 1, "accession" => replacement.filing.accession_no)
    expect(data.fetch("latest_report").fetch("accession")).to eq(replacement.filing.accession_no)
  end

  it "does not fall back to older holdings when the latest period is a notice" do
    report
    notice = report(period: Date.new(2026, 9, 30), submission_type: "13F-NT", report_type: "13F NOTICE", rows: [])
    data = profile.fetch("data")
    expect(data.fetch("portfolio_unavailable_reason")).to eq("no_effective_holdings")
    expect(data.fetch("reported_portfolio")).to include("value_usd" => nil, "complete" => false, "accession" => notice.filing.accession_no)
    expect(data.fetch("latest_report")).to include("accession" => notice.filing.accession_no, "report_type" => "13F NOTICE")
  end

  it "distinguishes latest cover evidence from the effective holdings source within one quarter" do
    base = report
    notice = report(submission_type: "13F-NT", report_type: "13F NOTICE", filed_at: Time.utc(2026, 8, 15), rows: [])
    data = profile.fetch("data")
    expect(data.dig("latest_report", "accession")).to eq(notice.filing.accession_no)
    expect(data.dig("reported_portfolio", "accession")).to eq(base.filing.accession_no)
    expect(data.dig("reported_portfolio", "value_usd")).to eq("100.0")
  end

  it "hides derived older Free metrics while retaining the existing latest-cover contract" do
    old = report(period: Date.new(2025, 9, 30))
    body = profile
    expect(body.fetch("data")).to include("reported_portfolio" => nil, "portfolio_unavailable_reason" => "history_restricted")
    expect(body.dig("data", "latest_report")).to include("accession" => old.filing.accession_no, "table_value_total" => "100.0")
    expect(body.fetch("meta")).to include("earliest_period" => "2025-12-31", "portfolio_history_limited" => true)
    with_billing_config do
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      pro = profile
      expect(pro.dig("data", "reported_portfolio", "value_usd")).to eq("100.0")
      expect(pro.fetch("meta")).to include("history_quarters" => nil, "earliest_period" => nil, "portfolio_history_limited" => false)
    end
  end

  it "pins cover and portfolio evidence to the same ingestion bounds before later inserts" do
    base = report
    history = Api::V1::HistoryWindow.new(limit: 4)
    query = Api::V1::FundProfileQuery.new(fund:, history:, as_of: Time.current)
    report(amendment_type: "RESTATEMENT", filed_at: Time.current, rows: [ { value_reported: 999 } ])
    create(:institutional_holding, institutional_report: base, value_reported: 999)
    other = create_13f(fund: create(:institutional_filer))
    create(:institutional_holding, institutional_report: other, value_reported: 999)
    body = query.call.deep_stringify_keys
    expect(body.dig("data", "latest_report", "accession")).to eq(base.filing.accession_no)
    expect(body.dig("data", "reported_portfolio", "accession")).to eq(base.filing.accession_no)
    expect(body.dig("data", "reported_portfolio", "value_usd")).to eq(BigDecimal("100"))
    expect(body.dig("data", "reported_portfolio", "complete")).to be(true)
  end

  it "returns a stored identity without reports and rejects unsupported profile filters without requests" do
    body = profile
    expect(body.fetch("data")).to include("cik" => fund.cik, "reported_portfolio" => nil, "latest_report" => nil,
      "portfolio_unavailable_reason" => "no_report")
    get api_v1_fund_path(fund.cik), params: { period: "2026-06-30" }
    expect(response).to have_http_status(:bad_request)
    get api_v1_fund_path("0000000001")
    expect(response).to have_http_status(:not_found)
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
