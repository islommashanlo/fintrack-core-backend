# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Fund directory report facts and coverage filters" do
  include InstitutionalReadHelpers
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }

  def report(fund: create(:institutional_filer), rows: [ {} ], **attributes)
    item = create_13f(fund:, **attributes)
    holdings = rows.map do |row|
      value = row.fetch(:value_reported, 100)
      create(:institutional_holding, institutional_report: item, value_reported: value, value_usd: value, **row)
    end
    item.update!(table_entry_total: holdings.length, table_value_total: holdings.sum(&:value_reported))
    item
  end

  def fetch(**parameters)
    get api_v1_funds_path, params: parameters
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    response.parsed_body
  end

  it "filters any contributing stored cover type and preserves each source label" do
    base = report(report_type: "13F HOLDINGS REPORT")
    addition = report(fund: base.institutional_filer, report_type: "13F COMBINATION REPORT",
      amendment_type: "NEW HOLDINGS", filed_at: Time.utc(2026, 8, 15))
    other = report(report_type: "13F HOLDINGS REPORT")
    row = fetch(report_type: "combination", coverage: "complete").fetch("data").sole
    expect(row.fetch("cik")).to eq(base.institutional_filer.cik)
    expect(row.dig("reported_portfolio", "report_types")).to eq([ "13F COMBINATION REPORT", "13F HOLDINGS REPORT" ])
    expect(row.dig("reported_portfolio", "sources").map { |source| source.slice("accession", "report_type") }).to eq([
      { "accession" => addition.filing.accession_no, "report_type" => "13F COMBINATION REPORT" },
      { "accession" => base.filing.accession_no, "report_type" => "13F HOLDINGS REPORT" }
    ])
    expect(fetch(report_type: "holdings").fetch("data").pluck("cik")).to contain_exactly(base.institutional_filer.cik, other.institutional_filer.cik)
  end

  it "distinguishes all existing coverage states without turning unknown values into zero" do
    complete = report(rows: [])
    incomplete = report(rows: [ { value_usd: nil } ])
    notice = report(submission_type: "13F-NT", report_type: "13F NOTICE", rows: [])
    absent = create(:institutional_filer)
    restricted = report(period: Date.new(2025, 9, 30))
    cases = { "complete" => complete.institutional_filer.cik, "incomplete_report_set" => incomplete.institutional_filer.cik,
      "no_effective_holdings" => notice.institutional_filer.cik, "no_report" => absent.cik, "history_restricted" => restricted.institutional_filer.cik }
    cases.each do |coverage, cik|
      body = fetch(coverage:)
      expect(body.fetch("data").pluck("cik")).to eq([ cik ])
      expect(body.dig("meta", "total_count")).to eq(1)
    end
    expect(fetch(coverage: "complete", max_position_count: "0").fetch("data").sole.dig("reported_portfolio", "value_usd")).to eq("0.0")
    expect(fetch(coverage: "incomplete_report_set", min_portfolio_value_usd: "0").fetch("data")).to eq([])
  end

  it "retains notice and orphan cover facts but cannot establish effective holdings" do
    notice = report(submission_type: "13F-NT", report_type: "13F NOTICE", rows: [])
    orphan = report(amendment_type: "NEW HOLDINGS", report_type: "13F COMBINATION REPORT")
    notice_row = fetch(report_type: "notice", coverage: "no_effective_holdings").fetch("data").sole
    expect(notice_row.dig("reported_portfolio", "report_types")).to eq([ "13F NOTICE" ])
    expect(notice_row.dig("reported_portfolio", "accession")).to eq(notice.filing.accession_no)
    expect(fetch(report_type: "combination", coverage: "no_effective_holdings").fetch("data").sole.fetch("cik")).to eq(orphan.institutional_filer.cik)
    expect(fetch(report_type: "notice", coverage: "complete").fetch("data")).to eq([])
  end

  it "excludes superseded and noncontributing cover types from the selected effective report set" do
    original = report(report_type: "13F COMBINATION REPORT")
    replacement = report(fund: original.institutional_filer, amendment_type: "RESTATEMENT", filed_at: Time.utc(2026, 8, 15))
    report(fund: original.institutional_filer, submission_type: "13F-NT", report_type: "13F NOTICE", filed_at: Time.utc(2026, 8, 16), rows: [])
    expect(fetch(report_type: "combination").fetch("data")).to eq([])
    expect(fetch(report_type: "notice").fetch("data")).to eq([])
    row = fetch(report_type: "holdings").fetch("data").sole
    expect(row.dig("reported_portfolio", "sources").pluck("accession")).to eq([ replacement.filing.accession_no ])
  end

  it "does not expose old report types through predicates for Free, but supports verified Pro" do
    old = report(period: Date.new(2025, 9, 30), report_type: "13F COMBINATION REPORT")
    hidden = fetch(coverage: "history_restricted").fetch("data").sole
    expect(hidden).to include("cik" => old.institutional_filer.cik, "reported_portfolio" => nil)
    expect(fetch(report_type: "combination").fetch("data")).to eq([])
    expect(fetch(report_type: "combination", coverage: "history_restricted").fetch("data")).to eq([])
    get api_v1_funds_path, params: { period: "2025-09-30", report_type: "combination", coverage: "complete" }
    expect(response).to have_http_status(:payment_required)
    with_billing_config do
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      row = fetch(report_type: "combination", coverage: "complete").fetch("data").sole
      expect(row.dig("reported_portfolio", "report_types")).to eq([ "13F COMBINATION REPORT" ])
    end
  end

  it "keeps type and coverage filters pinned through later amendments and scoped cursor changes" do
    first, second = 2.times.map { create(:institutional_filer) }
    report(fund: first)
    report(fund: second)
    body = fetch(report_type: "holdings", coverage: "complete", sort: "cik", limit: 1)
    report(fund: second, report_type: "13F COMBINATION REPORT", amendment_type: "RESTATEMENT", filed_at: Time.current)
    cursor = body.dig("meta", "next_cursor")
    next_body = fetch(report_type: "holdings", coverage: "complete", sort: "cik", limit: 1, cursor:)
    expect(next_body.fetch("data").sole.fetch("cik")).to eq(second.cik)
    expect(next_body.dig("data", 0, "reported_portfolio", "report_types")).to eq([ "13F HOLDINGS REPORT" ])
    [ { report_type: "combination", coverage: "complete" }, { report_type: "holdings", coverage: "incomplete_report_set" } ].each do |filters|
      get api_v1_funds_path, params: { **filters, sort: "cik", limit: 1, cursor: }
      expect(response).to have_http_status(:bad_request)
    end
  end

  it "preserves unfamiliar stored labels without guessing a classification" do
    report(report_type: "UNFAMILIAR REPORTED LABEL")
    row = fetch(coverage: "complete").fetch("data").sole
    expect(row.dig("reported_portfolio", "report_types")).to eq([ "UNFAMILIAR REPORTED LABEL" ])
    expect(fetch(report_type: "holdings").fetch("data")).to eq([])
  end

  it "rejects unsupported enum values and injection-shaped filters without requests or writes" do
    before = [ Filing.count, InstitutionalReport.count, InstitutionalHolding.count ]
    [ { report_type: "hedge_fund" }, { report_type: "holdings' OR 1=1--" }, { coverage: "unknown" },
      { coverage: "COMPLETE" }, { report_type: [ "holdings", "notice" ] }, { coverage: { status: "complete" } } ].each do |parameters|
      get api_v1_funds_path, params: parameters
      expect(response).to have_http_status(:bad_request), parameters.inspect
    end
    expect([ Filing.count, InstitutionalReport.count, InstitutionalHolding.count ]).to eq(before)
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
