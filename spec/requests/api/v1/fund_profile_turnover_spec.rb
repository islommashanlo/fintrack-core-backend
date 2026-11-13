# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reported allocation turnover on fund profiles" do
  include OpenapiResponses
  include InstitutionalReadHelpers
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }
  let(:fund) { create(:institutional_filer) }
  let(:current) { Date.new(2026, 9, 30) }
  let(:prior) { Date.new(2026, 6, 30) }

  def report(quarter: current, rows: [ {} ], **attributes)
    item = create_13f(fund:, period: quarter, filed_at: 2.days.ago, **attributes)
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
    expect_documented_response(path: "/funds/{cik}")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    response.parsed_body
  end

  def summary = profile.fetch("data").fetch("reported_allocation_turnover")

  it "reuses the standalone calculation and retains independent current/prior source evidence" do
    before = report(quarter: prior, rows: [ { value_reported: 25 }, { cusip: "594918104", value_reported: 75 } ])
    after = report(rows: [ { value_reported: 50 }, { cusip: "594918104", value_reported: 50 } ])
    data = profile.fetch("data")
    result = data.fetch("reported_allocation_turnover")
    expect(BigDecimal(result.fetch("reported_allocation_turnover_percent"))).to eq(25)
    expect(result).to include("status" => "available", "unavailable_reason" => nil, "current_complete" => true, "prior_complete" => true,
      "period_of_report" => current.iso8601, "prior_period_of_report" => prior.iso8601,
      "methodology_version" => "reported-allocation-turnover-v1", "baseline_policy" => "adjacent_calendar_quarter",
      "current_source_scope" => "effective_holdings", "prior_source_scope" => "effective_holdings", "accession" => after.filing.accession_no)
    expect(result.fetch("current_sources").pluck("accession")).to eq([ after.filing.accession_no ])
    expect(result.fetch("prior_sources").pluck("accession")).to eq([ before.filing.accession_no ])
    expect(data.dig("reported_portfolio", "value_usd")).to eq("100.0")
    get turnover_api_v1_fund_path(fund.cik)
    standalone = response.parsed_body.fetch("data")
    expect(result.slice("status", "unavailable_reason", "reported_allocation_turnover_percent", "accession", "filed_at"))
      .to eq(standalone.slice("status", "unavailable_reason", "reported_allocation_turnover_percent", "accession", "filed_at"))
  end

  it "retains later prior-quarter amendment provenance while preserving the latest-period cover" do
    report(quarter: prior)
    after = report
    amended = report(quarter: prior, amendment_type: "RESTATEMENT", filed_at: 1.day.ago,
      rows: [ { cusip: "594918104" } ])
    body = profile.fetch("data")
    result = body.fetch("reported_allocation_turnover")
    expect(BigDecimal(result.fetch("reported_allocation_turnover_percent"))).to eq(100)
    expect(result.fetch("accession")).to eq(amended.filing.accession_no)
    expect(body.dig("latest_report", "accession")).to eq(after.filing.accession_no)
    expect(result.fetch("prior_sources").pluck("accession")).to eq([ amended.filing.accession_no ])
  end

  it "distinguishes absent reports, missing baselines, zero change and incomplete or zero-value portfolios" do
    expect(summary).to include("status" => "unavailable", "unavailable_reason" => "no_current_report",
      "reported_allocation_turnover_percent" => nil, "period_of_report" => nil, "current_sources" => [], "prior_sources" => [])
    after = report
    expect(summary).to include("unavailable_reason" => "no_prior_report", "current_complete" => true, "prior_complete" => false)
    before = report(quarter: prior)
    expect(BigDecimal(summary.fetch("reported_allocation_turnover_percent"))).to eq(0)
    after.institutional_holdings.sole.update!(value_usd: nil)
    expect(summary).to include("unavailable_reason" => "incomplete_current_portfolio", "reported_allocation_turnover_percent" => nil,
      "current_complete" => false, "prior_complete" => true)
    after.institutional_holdings.sole.update!(value_usd: 100)
    before.update!(suspect: true)
    expect(summary.fetch("unavailable_reason")).to eq("incomplete_prior_portfolio")
    before.update!(suspect: false)
    after.institutional_holdings.sole.update!(value_reported: 0, value_usd: 0)
    after.update!(table_value_total: 0)
    expect(summary).to include("unavailable_reason" => "zero_current_portfolio_value", "current_complete" => true,
      "reported_allocation_turnover_percent" => nil)
    expect(profile.dig("data", "latest_report", "table_value_total")).to eq("0.0")
  end

  it "retains notice evidence without falling back to an older holdings quarter" do
    report(quarter: prior)
    notice = report(submission_type: "13F-NT", report_type: "13F NOTICE", rows: [])
    result = summary
    expect(result).to include("unavailable_reason" => "no_effective_current_holdings", "current_complete" => false,
      "prior_complete" => true, "current_source_scope" => "observed_reports", "period_of_report" => current.iso8601)
    expect(result.fetch("current_sources").pluck("accession")).to eq([ notice.filing.accession_no ])
  end

  it "uses effective holdings alongside a later same-quarter notice without substituting its cover" do
    report(quarter: prior)
    base = report
    notice = report(submission_type: "13F-NT", report_type: "13F NOTICE", rows: [], filed_at: 1.day.ago)
    body = profile.fetch("data")
    result = body.fetch("reported_allocation_turnover")
    expect(result.fetch("status")).to eq("available")
    expect(result.fetch("current_sources").pluck("accession")).to eq([ base.filing.accession_no ])
    expect(body.dig("latest_report", "accession")).to eq(notice.filing.accession_no)
  end

  it "redacts old Free turnover evidence while allowing Pro and rechecking after downgrade" do
    report(quarter: Date.new(2025, 6, 30))
    old = report(quarter: Date.new(2025, 9, 30))
    body = profile.fetch("data")
    restricted = body.fetch("reported_allocation_turnover")
    expect(restricted).to include("status" => "unavailable", "unavailable_reason" => "history_restricted",
      "reported_allocation_turnover_percent" => nil, "prior_period_of_report" => nil,
      "current_complete" => nil, "prior_complete" => nil, "current_sources" => [], "prior_sources" => [],
      "current_source_scope" => nil, "prior_source_scope" => nil, "accession" => nil, "sec_url" => nil)
    expect(body.dig("latest_report", "accession")).to eq(old.filing.accession_no)
    with_billing_config do
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      expect(BigDecimal(summary.fetch("reported_allocation_turnover_percent"))).to eq(0)
      apply_billing_event(id: "evt_profile_turnover_canceled", snapshot: billing_snapshot(status: "canceled"), type: "customer.subscription.deleted")
      expect(summary).to eq(restricted)
    end
  end

  it "allows the adjacent baseline outside the Free window for an accessible current quarter" do
    before = report(quarter: Date.new(2025, 9, 30))
    report(quarter: Date.new(2025, 12, 31))
    result = summary
    expect(BigDecimal(result.fetch("reported_allocation_turnover_percent"))).to eq(0)
    expect(result.fetch("prior_sources").pluck("accession")).to eq([ before.filing.accession_no ])
  end

  it "shares the profile source ceilings across late restatements and inserted holdings" do
    report(quarter: prior)
    base = report
    query = Api::V1::FundProfileQuery.new(fund:, history: Api::V1::HistoryWindow.new(limit: 4), as_of: Time.current)
    report(amendment_type: "RESTATEMENT", filed_at: Time.current, rows: [ { cusip: "594918104" } ])
    create(:institutional_holding, institutional_report: base, value_reported: 999)
    result = query.call.fetch(:data).fetch(:reported_allocation_turnover)
    expect(result.fetch(:reported_allocation_turnover_percent)).to eq(0)
    expect(result.fetch(:current_sources).pluck(:accession)).to eq([ base.filing.accession_no ])
  end

  it "does not admit a prior quarter inserted after the profile bounds were captured" do
    report
    query = Api::V1::FundProfileQuery.new(fund:, history: Api::V1::HistoryWindow.new(limit: 4), as_of: Time.current)
    report(quarter: prior)
    result = query.call.fetch(:data).fetch(:reported_allocation_turnover)
    expect(result).to include(unavailable_reason: "no_prior_report", reported_allocation_turnover_percent: nil, prior_sources: [])
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
