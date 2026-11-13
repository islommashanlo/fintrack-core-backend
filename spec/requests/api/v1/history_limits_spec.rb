# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 institutional history limits" do
  include OpenapiResponses
  include ApiAccounts
  include InstitutionalReadHelpers
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }
  let(:fund) { create(:institutional_filer) }
  let(:earliest) { Date.new(2025, 12, 31) }
  let(:older) { Date.new(2025, 9, 30) }

  def data = response.parsed_body.fetch("data")
  def meta = response.parsed_body.fetch("meta")

  def report(period, **attributes)
    create_13f(fund:, period:, filed_at: 2.days.ago, **attributes)
  end

  def row(report, **attributes)
    create(:institutional_holding, institutional_report: report, **attributes)
  end

  def paths
    [ holdings_api_v1_fund_path(fund.cik), history_api_v1_fund_path(fund.cik),
      changes_api_v1_fund_path(fund.cik), institutional_api_v1_company_path("ACME") ]
  end

  def check_fund_list_contract(path)
    case path
    when holdings_api_v1_fund_path(fund.cik)
      expect_documented_response(path: "/funds/{cik}/holdings")
    when changes_api_v1_fund_path(fund.cik)
      expect_documented_response(path: "/funds/{cik}/changes")
    end
  end

  def company
    create(:filing, issuer_ticker: "ACME", filed_at: 1.day.ago)
    map_security(cusip: "037833100", ticker: "ACME")
  end

  it "rejects explicit older quarters consistently on all quarterly history routes without writes or HTTP" do
    company
    old = report(older)
    holding = row(old)
    counts = [ Filing.count, InstitutionalReport.count, InstitutionalHolding.count, PositionDiff.count ]
    paths.each do |path|
      get path, params: { period: older.iso8601 }
      check_fund_list_contract(path)
      expect(response).to have_http_status(:payment_required), path
      expect(response.parsed_body).to eq("code" => "PRO_REQUIRED", "feature" => "history_quarters", "limit" => 4)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
    expect([ Filing.count, InstitutionalReport.count, InstitutionalHolding.count, PositionDiff.count ]).to eq(counts)
    expect(holding.reload.value_reported).to eq(100.to_d)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "includes the boundary quarter and distinguishes the cutoff from acceptance time" do
    company
    accepted = row(report(earliest))
    row(report(older, amendment_type: "RESTATEMENT", filed_at: 1.hour.ago))
    [ holdings_api_v1_fund_path(fund.cik), institutional_api_v1_company_path("ACME") ].each do |path|
      get path, params: { period: earliest.iso8601 }
      check_fund_list_contract(path)
      expect(response).to have_http_status(:ok)
      expect(data.pluck("id")).to eq([ accepted.id ])
      expect(meta).to include("history_quarters" => 4, "earliest_period" => earliest.iso8601,
        "feature" => "history_quarters", "truncated" => false, "accessible_count" => 1)
    end
  end

  it "previews report history using full and accessible counts without paging into older reports" do
    old = report(older)
    report(older, amendment_type: "RESTATEMENT", filed_at: 1.hour.ago)
    allowed = [ report(earliest), report(Date.new(2026, 3, 31)), report(Date.new(2026, 6, 30)) ]
    report(older, status: "failed")
    report(older, filed_at: 1.day.from_now)
    path = history_api_v1_fund_path(fund.cik)
    seen, cursor = [], nil
    loop do
      request_values = { sort: "period", limit: "1" }
      request_values[:cursor] = cursor if cursor
      get path, params: request_values
      check_fund_list_contract(path)
      expect(response).to have_http_status(:ok)
      expect(meta).to include("total_count" => 5, "accessible_count" => 3, "truncated" => true, "feature" => "history_quarters")
      seen += data.pluck("id")
      cursor = meta.fetch("next_cursor")
      break unless cursor
    end
    expect(seen).to eq(allowed.map(&:id))
    expect(seen).not_to include(old.id)
    expect(meta.fetch("has_more")).to be(false)
  end

  it "gates stale default fund periods instead of silently selecting a different period" do
    row(report(older))
    [ holdings_api_v1_fund_path(fund.cik), changes_api_v1_fund_path(fund.cik) ].each do |path|
      get path
      check_fund_list_contract(path)
      expect(response).to have_http_status(:payment_required)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
    get api_v1_fund_path(fund.cik)
    expect(response).to have_http_status(:ok)
    expect(data.fetch("latest_report").fetch("period_of_report")).to eq(older.iso8601)
  end

  it "clips mixed-period company ownership after resolving each fund's latest period" do
    company
    hidden = row(report(older, filed_at: 1.hour.ago), put_call: "PUT")
    other = create(:institutional_filer)
    recent = create_13f(fund: other, period: Date.new(2026, 6, 30), filed_at: 3.days.ago)
    visible = row(recent)
    get institutional_api_v1_company_path("ACME")
    expect(data.pluck("id")).to eq([ visible.id ])
    expect(meta).to include("total_count" => 2, "accessible_count" => 1, "truncated" => true)
    get institutional_api_v1_company_path("ACME"), params: { put_call: "PUT" }
    expect(data).to eq([])
    expect(meta).to include("total_count" => 1, "accessible_count" => 0, "truncated" => true, "has_more" => false)
    expect(hidden.reload.put_call).to eq("PUT")
  end

  it "preserves baseline evidence outside the allowed window when calculating an allowed quarter" do
    previous = report(older, filed_at: Time.utc(2025, 11, 14))
    current = report(earliest, filed_at: Time.utc(2026, 2, 14))
    row(previous, shares: 100, value_usd: 1000)
    row(current, shares: 150, value_usd: 1500)
    restatement = report(older, amendment_type: "RESTATEMENT", filed_at: 1.hour.ago)
    row(restatement, shares: 75, value_usd: 750)
    get changes_api_v1_fund_path(fund.cik), params: { period: earliest.iso8601 }
    expect_documented_response(path: "/funds/{cik}/changes")
    expect(response).to have_http_status(:ok)
    expect(data.sole).to include("change_type" => "added", "shares_before" => "75.0", "shares_after" => "150.0", "shares_delta" => "75.0")
    expect(data.sole.fetch("prior_sources").pluck("accession")).to eq([ restatement.filing.accession_no ])
    expect(meta).to include("truncated" => false, "history_quarters" => 4)
  end

  it "allows verified Pro full history and invalidates paid cursors immediately after downgrade" do
    with_billing_config do
      company
      old = report(older)
      row(old)
      row(old)
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      paths.each do |path|
        get path, params: { period: older.iso8601 }
        check_fund_list_contract(path)
        expect(response).to have_http_status(:ok), path
        expect(data).not_to be_empty
        expect(meta).to include("history_quarters" => nil, "earliest_period" => nil, "truncated" => false)
        expect(response.headers["Cache-Control"]).to eq("no-store")
      end
      get holdings_api_v1_fund_path(fund.cik), params: { period: older.iso8601, limit: "1" }
      expect_documented_response(path: "/funds/{cik}/holdings")
      cursor = meta.fetch("next_cursor")
      apply_billing_event(id: "evt_history_canceled", snapshot: billing_snapshot(status: "canceled"), type: "customer.subscription.deleted")
      get holdings_api_v1_fund_path(fund.cik), params: { period: older.iso8601, limit: "1", cursor: }
      expect_documented_response(path: "/funds/{cik}/holdings")
      expect(response).to have_http_status(:bad_request)
      get holdings_api_v1_fund_path(fund.cik), params: { period: older.iso8601 }
      expect_documented_response(path: "/funds/{cik}/holdings")
      expect(response).to have_http_status(:payment_required)
    end
  end

  it "scopes report/company cursors to their actor and entitlement context" do
    company
    recent = report(earliest)
    row(recent)
    row(recent)
    report(Date.new(2026, 6, 30))
    routes = [ history_api_v1_fund_path(fund.cik), institutional_api_v1_company_path("ACME") ]
    cursors = routes.to_h do |path|
      get path, params: { period: earliest.iso8601, limit: "1" }
      check_fund_list_contract(path)
      # Add another report in the same period to make report-history pagination meaningful.
      if path == routes.first
        report(earliest, amendment_type: "NEW HOLDINGS", filed_at: 1.hour.ago)
        get path, params: { period: earliest.iso8601, limit: "1" }
        check_fund_list_contract(path)
      end
      [ path, meta.fetch("next_cursor") ]
    end
    user = create(:user, password: "password123")
    api_login(user)
    routes.each do |path|
      get path, params: { period: earliest.iso8601, limit: "1", cursor: cursors.fetch(path) }
      check_fund_list_contract(path)
      expect(response).to have_http_status(:bad_request)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  it "pins default holdings and change quarters when existing pending reports become parsed mid-page" do
    selected = report(Date.new(2026, 6, 30))
    %w[037833100 594918104].each { |cusip| row(selected, cusip:) }
    pending = report(Date.new(2026, 9, 30), status: "pending")
    row(pending, cusip: "023135106")
    routes = [ holdings_api_v1_fund_path(fund.cik), changes_api_v1_fund_path(fund.cik) ]
    snapshots = routes.to_h do |path|
      get path, params: { sort: "cusip", limit: "1" }
      check_fund_list_contract(path)
      [ path, [ meta.fetch("next_cursor"), data.first.fetch("cusip") ] ]
    end
    pending.update!(status: "parsed")
    routes.each do |path|
      cursor, first_key = snapshots.fetch(path)
      get path, params: { sort: "cusip", limit: "1", cursor: }
      check_fund_list_contract(path)
      expect(response).to have_http_status(:ok)
      expect(data.sole.fetch("cusip")).not_to eq(first_key)
      expect(data.sole.fetch("period_of_report")).to eq("2026-06-30")
    end
  end

  it "anchors the window to the cursor snapshot while fresh requests roll at a calendar-quarter boundary" do
    recent = report(earliest)
    row(recent)
    row(recent)
    travel_to Time.utc(2026, 12, 31, 23, 55)
    get holdings_api_v1_fund_path(fund.cik), params: { period: earliest.iso8601, limit: "1" }
    expect_documented_response(path: "/funds/{cik}/holdings")
    cursor = meta.fetch("next_cursor")
    travel_to Time.utc(2027, 1, 1, 0, 5)
    get holdings_api_v1_fund_path(fund.cik), params: { period: earliest.iso8601, limit: "1", cursor: }
    expect_documented_response(path: "/funds/{cik}/holdings")
    expect(response).to have_http_status(:ok)
    expect(meta.fetch("earliest_period")).to eq("2025-12-31")
    get holdings_api_v1_fund_path(fund.cik), params: { period: earliest.iso8601 }
    expect_documented_response(path: "/funds/{cik}/holdings")
    expect(response).to have_http_status(:payment_required)
  end

  it "retains the public Form 4 filing surface and gives honest empty previews with private error responses" do
    company
    historical = create(:filing, issuer_ticker: "ACME", filed_at: Time.utc(2010, 1, 1))
    get filings_api_v1_company_path("ACME")
    expect(data.pluck("accession")).to include(historical.accession_no)
    paths.each do |path|
      get path
      check_fund_list_contract(path)
      expect(response).to have_http_status(:ok)
      expect(data).to eq([])
      expect(meta).to include("truncated" => false, "accessible_count" => 0, "total_count" => 0)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      get path, params: { period: "not-a-date" }
      check_fund_list_contract(path)
      expect(response).to have_http_status(:bad_request)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end
end
