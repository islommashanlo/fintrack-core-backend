# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 company institutional history" do
  include ApiAccounts
  include InstitutionalReadHelpers
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }
  let(:fund) { create(:institutional_filer) }
  let(:period) { Date.new(2026, 9, 30) }
  let(:prior) { Date.new(2026, 6, 30) }
  let(:older) { Date.new(2025, 9, 30) }

  before do
    create(:filing, issuer_ticker: "ACME", filed_at: 1.day.ago)
    map_security(cusip: "037833100", ticker: "ACME")
  end

  def data = response.parsed_body.fetch("data")
  def meta = response.parsed_body.fetch("meta")
  def history(**values)
    get history_api_v1_company_path("acme"), params: values
  end

  def report(quarter = period, manager: fund, **values)
    create_13f(fund: manager, period: quarter, filed_at: 2.days.ago, **values)
  end

  def holding(report, **values)
    create(:institutional_holding, institutional_report: report, **values)
  end

  it "groups repeated reported rows in SQL and supplies quarterly and position source evidence" do
    previous = report(prior)
    holding(previous, shares: 50)
    current = report
    holding(current, shares: 100, value_usd: 1000)
    holding(current, shares: 25, value_usd: 250, investment_discretion: "DFND")
    history
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(data.pluck("period_of_report")).to eq([ period.iso8601, prior.iso8601 ])
    expect(data.first).to include("holder_count" => 1, "observed_holder_count" => 1, "holding_row_count" => 2,
      "complete" => true, "holder_count_delta" => 0, "prior_period_of_report" => prior.iso8601,
      "expected_fund_count" => 1, "reporting_fund_count" => 1, "missing_fund_count" => 0,
      "accession" => current.filing.accession_no, "sec_url" => current.filing.sec_url, "data_age_days" => 2)
    position = data.first.fetch("positions").sole
    expect(position).to include("cusip" => "037833100", "row_count" => 2, "source_count" => 1,
      "shares" => "125.0", "value_usd" => "1250.0", "shares_reported" => "125.0",
      "accession" => current.filing.accession_no)
    expect(data.first.fetch("sources").pluck("accession")).to eq([ current.filing.accession_no ])
    expect(data.first.fetch("detail_path")).to eq("/api/v1/companies/ACME/institutional?period=2026-09-30")
    expect(position.fetch("detail_path")).to include("cusip=037833100", "share_type=SH")
    expect(meta).to include("ticker" => "ACME", "available" => true, "cohort_fund_count" => 1,
      "mapping_policy" => "current_local_cache", "marketwide_ownership_available" => false,
      "missing_periods_filled" => false, "accessible_count" => 2, "truncated" => false)
  end

  it "distinguishes incomplete cohort coverage from a known empty report and counts each fund once" do
    other = create(:institutional_filer)
    [ fund, other ].each { |manager| holding(report(prior, manager:)) }
    report # A valid empty report from one fund; the other is missing.
    history
    expect(data.first).to include("observed_holder_count" => 0, "holder_count" => nil, "complete" => false,
      "expected_fund_count" => 2, "reporting_fund_count" => 1, "missing_fund_count" => 1, "holder_count_delta" => nil)
    expect(data.first.fetch("positions")).to eq([])
    report(manager: other)
    history
    expect(data.first).to include("holder_count" => 0, "complete" => true, "reporting_fund_count" => 2, "holder_count_delta" => -2)
  end

  it "omits missing quarters and never compares across a gap" do
    holding(report(Date.new(2026, 3, 31)))
    holding(report)
    history
    expect(data.pluck("period_of_report")).to eq([ period.iso8601, "2026-03-31" ])
    expect(data.first.fetch("holder_count_delta")).to be_nil
  end

  it "resolves restatements and later additions without double-counting superseded rows" do
    original = report(filed_at: 4.days.ago)
    holding(original, shares: 999)
    restatement = report(amendment_type: "RESTATEMENT", filed_at: 3.days.ago)
    holding(restatement, shares: 20)
    addition = report(amendment_type: "NEW HOLDINGS", filed_at: 1.day.ago)
    holding(addition, shares: 5)
    history
    expect(data.sole).to include("holder_count" => 1, "source_count" => 2, "holding_row_count" => 2)
    expect(data.sole.fetch("positions").sole).to include("shares" => "25.0", "source_count" => 2)
    expect(data.sole.fetch("sources").pluck("accession")).to eq([ addition.filing.accession_no, restatement.filing.accession_no ])
    expect(original.reload.institutional_holdings.sole.shares).to eq(999)
  end

  it "keeps option, principal and CUSIP keys separate while filters preserve the reporting cohort" do
    map_security(cusip: "594918104", ticker: "ACME", figi: "BBG000000002")
    current = report
    holding(current)
    holding(current, put_call: "CALL")
    holding(current, share_type: "PRN")
    holding(current, cusip: "594918104")
    other = create(:institutional_filer)
    holding(report(manager: other), cusip: "594918104")
    history
    expect(data.sole).to include("position_count" => 4, "holder_count" => 2)
    expect(data.sole.fetch("positions").map { |p| p.values_at("cusip", "put_call", "share_type") }.uniq.size).to eq(4)
    history(cusip: "037833100", put_call: "CALL", share_type: "SH")
    expect(data.sole).to include("holder_count" => 1, "expected_fund_count" => 2, "complete" => true)
    expect(data.sole.fetch("positions").sole).to include("put_call" => "CALL", "share_type" => "SH")
    expect(data.sole.fetch("detail_path")).to include("cusip=037833100", "put_call=CALL", "share_type=SH")
  end

  it "retains reported quantities but withholds comparable quantities for suspect rows and missing normalization" do
    current = report
    suspect = holding(current, suspect: true, shares: -1, value_reported: 123, value_usd: 123)
    holding(current, put_call: "PUT", value_usd: nil)
    history
    expect(data.sole).to include("complete" => true, "suspect" => true, "holder_count" => 1)
    plain, option = data.sole.fetch("positions")
    expect(plain).to include("shares_reported" => "-1.0", "value_usd_reported" => "123.0", "shares" => nil, "value_usd" => nil, "suspect" => true)
    expect(option).to include("shares" => "10.0", "value_usd" => nil, "value_usd_reported" => nil)
    expect(suspect.reload.value_reported).to eq(123)
  end

  it "flags report anomalies and malformed keys instead of asserting complete coverage" do
    current = report(suspect: true)
    holding(current)
    holding(current, cusip: "INVALID")
    history
    expect(data.sole).to include("complete" => false, "holder_count" => nil, "suspect" => true,
      "suspect_report_fund_count" => 1, "excluded_holding_rows" => 1, "holding_row_count" => 1)
    expect(data.sole.fetch("positions").sole).to include("shares_reported" => "10.0", "shares" => nil)
  end

  it "shows notice-only and unresolved additive quarters as incomplete with source evidence" do
    holding(report(Date.new(2026, 3, 31)))
    notice = report(prior, submission_type: "13F-NT", report_type: "13F NOTICE")
    addition = report(amendment_type: "NEW HOLDINGS")
    holding(addition, shares: 999)
    history
    expect(data.first(2)).to all(include("complete" => false, "holder_count" => nil, "reporting_fund_count" => 0, "positions" => []))
    expect(data.first.fetch("sources").sole).to include("accession" => addition.filing.accession_no, "amendment_type" => "NEW HOLDINGS")
    expect(data.second).to include("notice_fund_count" => 1, "accession" => notice.filing.accession_no)
  end

  it "excludes failed, future and skipped reports and uses exact eligible local mappings" do
    holding(report(prior))
    [ { status: "failed" }, { status: "skipped" }, { filed_at: 1.day.from_now } ].each do |values|
      holding(report(manager: create(:institutional_filer), **values))
    end
    failed = report(manager: create(:institutional_filer))
    failed.filing.update!(parse_status: "failed")
    holding(failed)
    map_security(cusip: "594918104", ticker: "ACME.A", figi: "BBG000000002")
    holding(report(manager: create(:institutional_filer)), cusip: "594918104", name_of_issuer: "ACME")
    history
    expect(meta.fetch("cohort_fund_count")).to eq(1)
    expect(data.pluck("period_of_report")).to eq([ prior.iso8601 ])
    CusipSecurityMapping.find_by!(cusip: "037833100").update!(status: "ambiguous")
    history
    expect(data).to eq([])
    expect(meta).to include("available" => false, "unavailable_reason" => "mapping_unavailable")
  end

  it "returns an honest empty series when mapped securities have no local holdings" do
    counts = [ Filing.count, InstitutionalReport.count, InstitutionalHolding.count ]
    history
    expect(data).to eq([])
    expect(meta).to include("available" => false, "unavailable_reason" => "no_local_holdings", "cohort_fund_count" => 0)
    expect([ Filing.count, InstitutionalReport.count, InstitutionalHolding.count ]).to eq(counts)
    expect(WebMock).not_to have_requested(:any, /./)
    expect(enqueued_jobs).to be_empty
  end

  it "bounds source previews while keeping totals and quantities over all matching funds" do
    21.times { holding(report(manager: create(:institutional_filer))) }
    history
    expect(data.sole).to include("holder_count" => 21, "source_count" => 21, "sources_truncated" => true)
    expect(data.sole.fetch("sources").size).to eq(20)
    expect(data.sole.fetch("positions").sole).to include("shares" => "210.0", "source_count" => 21)
    expect(meta).to include("source_limit" => 20, "position_limit" => 100)
  end

  it "bounds position previews without losing counts or loading one query per position" do
    current = report
    holding(current)
    measure = lambda do
      queries = []
      callback = lambda { |*args| queries << args.last[:sql] unless args.last[:name] == "SCHEMA" || args.last[:cached] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { history }
      expect(response).to have_http_status(:ok)
      queries.grep(/\ASELECT|\AWITH/).length
    end
    baseline = measure.call
    100.times do |index|
      cusip = format("%09d", index)
      map_security(cusip:, ticker: "ACME", figi: format("BBG%09d", 1000 + index))
      holding(current, cusip:)
    end
    expect(measure.call).to be <= baseline + 1
    expect(data.sole).to include("position_count" => 101, "positions_truncated" => true, "holding_row_count" => 101)
    expect(data.sole.fetch("positions").size).to eq(100)
    expect(data.sole.fetch("positions").pluck("cusip")).to eq((0...100).map { |i| format("%09d", i) })
  end

  it "computes an adjacent delta before history clipping and gives explicit Free preview metadata" do
    baseline = report(older)
    holding(baseline)
    report(Date.new(2025, 12, 31))
    history
    expect(data.sole).to include("period_of_report" => "2025-12-31", "holder_count" => 0,
      "holder_count_delta" => -1, "prior_period_of_report" => older.iso8601)
    expect(data.sole.fetch("prior_sources").pluck("accession")).to eq([ baseline.filing.accession_no ])
    expect(data.sole).to include("prior_source_count" => 1, "prior_sources_truncated" => false)
    expect(meta).to include("total_count" => 2, "accessible_count" => 1, "truncated" => true,
      "earliest_period" => "2025-12-31", "has_more" => false)
    history(period: older.iso8601)
    expect(response).to have_http_status(:payment_required)
    expect(response.parsed_body).to eq("code" => "PRO_REQUIRED", "feature" => "history_quarters", "limit" => 4)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "paginates tied holder counts with snapshot bounds and rejects changed filters or actors" do
    [ Date.new(2026, 3, 31), prior, period ].each { |quarter| holding(report(quarter)) }
    history(sort: "holders", limit: "1")
    cursor, snapshot = meta.values_at("next_cursor", "as_of")
    expect(data.sole.fetch("period_of_report")).to eq("2026-03-31")
    holding(report(prior, amendment_type: "RESTATEMENT", filed_at: 1.hour.ago), shares: 999)
    history(sort: "holders", limit: "1", cursor:)
    expect(data.sole.fetch("period_of_report")).to eq(prior.iso8601)
    expect(data.sole.fetch("positions").sole.fetch("shares")).to eq("10.0")
    expect(meta.fetch("as_of")).to eq(snapshot)
    history(sort: "holders", limit: "1", cursor:, put_call: "PUT")
    expect(response).to have_http_status(:bad_request)
    api_login(create(:user, password: "password123"))
    history(sort: "holders", limit: "1", cursor:)
    expect(response).to have_http_status(:bad_request)
  end

  it "allows verified Pro full history and rejects a paid cursor after downgrade" do
    with_billing_config do
      [ older, prior, period ].each { |quarter| holding(report(quarter)) }
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      history(sort: "period", limit: "1")
      expect(data.sole.fetch("period_of_report")).to eq(older.iso8601)
      expect(meta).to include("history_quarters" => nil, "earliest_period" => nil, "truncated" => false, "total_count" => 3)
      cursor = meta.fetch("next_cursor")
      apply_billing_event(id: "evt_company_history_canceled", snapshot: billing_snapshot(status: "canceled"), type: "customer.subscription.deleted")
      history(sort: "period", limit: "1", cursor:)
      expect(response).to have_http_status(:bad_request)
      history(period: older.iso8601)
      expect(response).to have_http_status(:payment_required)
    end
  end

  it "validates filters, quarter dates, sorts, cursors and company identity with private errors" do
    [ { period: "2026-01-01" }, { put_call: "OTHER" }, { share_type: "OTHER" }, { cusip: "' OR 1=1" },
      { sort: "unknown" }, { limit: "101" }, { cursor: "invalid" }, { scope: "all" } ].each do |values|
      history(**values)
      expect(response).to have_http_status(:bad_request), values.inspect
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
    get history_api_v1_company_path("UNKNOWN")
    expect(response).to have_http_status(:not_found)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end
end
