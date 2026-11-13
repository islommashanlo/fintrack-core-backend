# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Shared fund screener history and integrity policy" do
  include OpenapiResponses
  include ApiAccounts
  include InstitutionalReadHelpers
  around { |example| travel_to(Time.utc(2026, 11, 13, 12)) { example.run } }
  let(:fund) { create(:institutional_filer) }
  let(:current) { Date.new(2026, 9, 30) }

  def report(rows: [ {} ], **attributes)
    item = create_13f(fund:, period: current, filed_at: 2.days.ago, **attributes)
    holdings = rows.map do |row|
      value = row.fetch(:value_reported, 100)
      create(:institutional_holding, institutional_report: item, value_reported: value, value_usd: value, **row)
    end
    item.update!(table_entry_total: holdings.length, table_value_total: holdings.sum(&:value_reported))
    item
  end

  def screen(filters: [], **options)
    post api_v1_screener_run_path, params: { entity: "funds", filters:, **options }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/screener/run", method: :post)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    response.parsed_body
  end

  def metrics = screen.fetch("data").sole.fetch("metrics")

  it "matches directory integrity for repeated keys, options and normalized reported totals" do
    report(rows: [ {}, { investment_discretion: "OTHER" }, { put_call: "PUT" }, { share_type: "PRN" } ])
    result = screen.fetch("data").sole
    get api_v1_funds_path, params: { q: fund.cik }
    portfolio = response.parsed_body.fetch("data").sole.fetch("reported_portfolio")
    expect(result.fetch("metrics")).to include("holding_row_count" => portfolio.fetch("holding_row_count"),
      "position_count" => portfolio.fetch("position_count"), "portfolio_value_usd" => portfolio.fetch("value_usd"), "suspect" => false)
    expect(result.fetch("fund_metrics_unavailable_reason")).to be_nil
    expect(result.fetch("source_filing_count")).to eq(portfolio.fetch("effective_report_count"))
  end

  it "withholds position counts and values for malformed rows while retaining observed row counts" do
    source = report(rows: [ {}, { cusip: "BAD" } ])
    result = screen.fetch("data").sole
    expect(result.fetch("metrics")).to include("holding_row_count" => 2, "position_count" => nil, "portfolio_value_usd" => nil, "suspect" => true)
    expect(result).to include("fund_metrics_unavailable_reason" => "incomplete_report_set", "source_filing_count" => 1,
      "accession" => source.filing.accession_no)
    expect(screen(filters: [ { field: "position_count", operator: "gte", value: 0 } ]).fetch("data")).to eq([])
    expect(source.institutional_holdings.pluck(:cusip)).to include("BAD")
  end

  it "uses shared checks for unresolved originals, normalization and cover mismatches" do
    source = report(amendment_type: "RESTATEMENT")
    expect(metrics).to include("portfolio_value_usd" => nil, "position_count" => nil, "suspect" => true)
    report(filed_at: 3.days.ago)
    expect(metrics).to include("portfolio_value_usd" => "100.0", "position_count" => 1, "suspect" => false)
    source.institutional_holdings.sole.update!(value_usd: 1000)
    expect(metrics).to include("portfolio_value_usd" => nil, "position_count" => nil, "suspect" => true)
    source.institutional_holdings.sole.update!(value_usd: 100)
    source.update!(table_entry_total: 2)
    expect(metrics).to include("holding_row_count" => 1, "position_count" => nil, "suspect" => true)
  end

  it "keeps notices and orphan additions unknown while valid empty holdings remain zero" do
    source = report(submission_type: "13F-NT", report_type: "13F NOTICE", rows: [])
    result = screen.fetch("data").sole
    expect(result.fetch("metrics")).to include("holding_row_count" => nil, "position_count" => nil, "portfolio_value_usd" => nil, "suspect" => nil)
    expect(result).to include("fund_metrics_unavailable_reason" => "no_effective_holdings", "source_filing_count" => 0)
    source.update!(submission_type: "13F-HR/A", amendment_type: "NEW HOLDINGS")
    source.filing.update!(form_type: "13F-HR/A")
    expect(screen.fetch("data").sole.fetch("fund_metrics_unavailable_reason")).to eq("no_effective_holdings")
    source.filing.update!(parse_status: "failed")
    report(rows: [])
    result = screen(filters: [ { field: "portfolio_value_usd", operator: "eq", value: 0 } ]).fetch("data").sole
    expect(result.fetch("metrics")).to include("holding_row_count" => 0, "position_count" => 0, "portfolio_value_usd" => "0.0", "suspect" => false)
    expect(result.fetch("source_filing_count")).to eq(1)
  end

  it "redacts old Free derived fields and source counts while keeping filing identity visible" do
    source = report(period: Date.new(2025, 9, 30))
    body = screen
    result = body.fetch("data").sole
    expect(result.fetch("metrics").values).to all(be_nil)
    expect(result).to include("fund_metrics_unavailable_reason" => "history_restricted", "source_filing_count" => nil,
      "cik" => fund.cik, "accession" => source.filing.accession_no, "period_of_report" => "2025-09-30")
    expect(body.fetch("meta")).to include("history_quarters" => 4, "earliest_period" => "2025-12-31", "fund_metrics_policy_version" => 3)
    %w[holding_row_count position_count portfolio_value_usd].each do |field|
      expect(screen(filters: [ { field:, operator: "gte", value: 0 } ]).fetch("data")).to eq([])
    end
    expect(screen(filters: [ { field: "suspect", operator: "eq", value: false } ]).fetch("data")).to eq([])
    expect(screen(filters: [ { field: "portfolio_value_usd", operator: "is_null" } ]).fetch("data").sole.fetch("cik")).to eq(fund.cik)
  end

  it "reveals complete old metrics only for verified Pro and rechecks after downgrade" do
    report(period: Date.new(2025, 9, 30))
    with_billing_config do
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      body = screen
      expect(body.fetch("data").sole.fetch("metrics")).to include("portfolio_value_usd" => "100.0", "position_count" => 1, "holding_row_count" => 1)
      expect(body.fetch("meta")).to include("history_quarters" => nil, "earliest_period" => nil, "fund_metrics_policy_version" => 3)
      apply_billing_event(id: "evt_fund_policy_canceled", snapshot: billing_snapshot(status: "canceled"), type: "customer.subscription.deleted")
      expect(screen.fetch("data").sole.fetch("metrics").values).to all(be_nil)
    end
  end

  it "preserves the same Free prefix through null sorts and bounded late report changes" do
    source = report
    second = create(:institutional_filer)
    third = create(:institutional_filer)
    create_13f(fund: second, period: Date.new(2025, 9, 30))
    create_13f(fund: third, submission_type: "13F-NT", report_type: "13F NOTICE")
    body = screen(sort: "-portfolio_value_usd", limit: 1)
    expect(body.fetch("data").sole.fetch("cik")).to eq(fund.cik)
    report(amendment_type: "RESTATEMENT", filed_at: Time.current, rows: [ { value_reported: 999 } ])
    create(:institutional_holding, institutional_report: source, value_reported: 999)
    seen = [ fund.cik ]
    while body.dig("meta", "next_cursor")
      body = screen(sort: "-portfolio_value_usd", limit: 1, cursor: body.dig("meta", "next_cursor"))
      seen.concat(body.fetch("data").pluck("cik"))
    end
    expect(seen).to eq([ fund.cik, third.cik, second.cik ])
    expect(body.fetch("meta")).to include("total_count" => 3, "has_more" => false)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "requires restart for fund cursors signed under the earlier metrics policy" do
    report
    create_13f(fund: create(:institutional_filer))
    body = screen(limit: 1)
    verifier = Rails.application.message_verifier("api.v1.read_pages")
    payload = verifier.verify(body.dig("meta", "next_cursor"), purpose: "pagination")
    payload.fetch("context")["fund_metrics_version"] = 2
    old_cursor = verifier.generate(payload, purpose: "pagination", expires_in: 24.hours)
    post api_v1_screener_run_path, params: { entity: "funds", limit: 1, cursor: old_cursor }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
  end
end
