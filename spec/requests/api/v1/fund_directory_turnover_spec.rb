# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reported allocation turnover in the fund directory" do
  include OpenapiResponses
  include InstitutionalReadHelpers
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }
  let(:current) { Date.new(2026, 9, 30) }
  let(:prior) { Date.new(2026, 6, 30) }
  let(:field) { "reported_allocation_turnover_percent" }

  def report(fund:, quarter: current, rows: [ {} ], **attributes)
    item = create_13f(fund:, period: quarter, filed_at: 2.days.ago, **attributes)
    holdings = rows.map do |row|
      value = row.fetch(:value_reported, 100)
      create(:institutional_holding, institutional_report: item, value_reported: value, value_usd: value, **row)
    end
    item.update!(table_entry_total: holdings.length, table_value_total: holdings.sum(&:value_reported))
    item
  end

  def pair(fund, rows: [ {} ], quarter: current, **attributes)
    report(fund:, quarter: (quarter << 3).end_of_quarter)
    report(fund:, quarter:, rows:, **attributes)
  end

  def fetch(**parameters)
    get api_v1_funds_path, params: parameters
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/funds")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    response.parsed_body
  end

  def summaries(body) = body.fetch("data").to_h { |row| [ row.fetch("cik"), row.fetch("reported_allocation_turnover") ] }

  it "filters inclusive full-portfolio percentages with source evidence and standalone/profile parity" do
    unchanged, half, replaced, missing = 4.times.map { create(:institutional_filer) }
    pair(unchanged)
    pair(half, rows: [ { value_reported: 50 }, { cusip: "594918104", value_reported: 50 } ])
    pair(replaced, rows: [ { cusip: "594918104" } ])
    report(fund: missing)
    body = fetch("min_#{field}" => "0", "max_#{field}" => "50", sort: field)
    expect(body.fetch("data").pluck("cik")).to eq([ unchanged.cik, half.cik ])
    result = summaries(body).fetch(half.cik)
    expect(result.fetch(field)).to be_a(String)
    expect(BigDecimal(result.fetch(field))).to eq(50)
    expect(result).to include("status" => "available", "current_complete" => true, "prior_complete" => true,
      "period_of_report" => current.iso8601, "prior_period_of_report" => prior.iso8601)
    expect(result.fetch("current_sources").length).to eq(1)
    expect(result.fetch("prior_sources").length).to eq(1)
    expect(fetch("min_#{field}" => "50", "max_#{field}" => "50").fetch("data").pluck("cik")).to eq([ half.cik ])
    expect(body.fetch("meta")).to include("turnover_methodology_version" => "reported-allocation-turnover-v1",
      "turnover_baseline_policy" => "adjacent_calendar_quarter", "total_count" => 2)
    get api_v1_fund_path(half.cik)
    expect(response.parsed_body.dig("data", "reported_allocation_turnover")).to eq(result)
    get turnover_api_v1_fund_path(half.cik)
    standalone = response.parsed_body.fetch("data")
    expect(result.slice(field, "status", "unavailable_reason", "accession")).to eq(standalone.slice(field, "status", "unavailable_reason", "accession"))
  end

  it "combines turnover with current report-type, coverage and portfolio filters" do
    fund = create(:institutional_filer)
    report(fund:, quarter: prior, report_type: "13F COMBINATION REPORT")
    report(fund:)
    filters = { "min_#{field}" => "0", coverage: "complete", min_portfolio_value_usd: "100", min_position_count: "1" }
    expect(fetch(**filters, report_type: "holdings").fetch("data").pluck("cik")).to eq([ fund.cik ])
    expect(fetch(**filters, report_type: "combination").fetch("data")).to eq([])
  end

  it "resolves amendments, repeated rows and separate option/principal keys for every fund" do
    fund, other = 2.times.map { create(:institutional_filer) }
    report(fund:, quarter: prior, rows: [ { value_reported: 50 }, { put_call: "PUT", value_reported: 25 }, { share_type: "PRN", value_reported: 25 } ])
    report(fund:, rows: [ { value_reported: 999 } ])
    base = report(fund:, amendment_type: "RESTATEMENT", filed_at: 1.day.ago, rows: [ { value_reported: 10 }, { value_reported: 15 }, { share_type: "PRN", value_reported: 25 } ])
    added = report(fund:, amendment_type: "NEW HOLDINGS", filed_at: 1.hour.ago, rows: [ { put_call: "CALL", value_reported: 25 }, { cusip: "594918104", value_reported: 25 } ])
    pair(other, rows: [ { cusip: "594918104" } ])
    result = summaries(fetch(sort: field)).fetch(fund.cik)
    expect(BigDecimal(result.fetch(field))).to eq(50)
    expect(result.fetch("current_sources").pluck("accession")).to eq([ base.filing.accession_no, added.filing.accession_no ])
    expect(result.fetch("accession")).to eq(added.filing.accession_no)
  end

  it "uses each fund's latest quarter or an explicit quarter and never bridges a missing baseline" do
    latest, earlier, gap = 3.times.map { create(:institutional_filer) }
    pair(latest)
    pair(earlier, quarter: prior, cover_value_unit: "thousands", rows: [ { value_reported: BigDecimal("0.1"), value_unit: "thousands", value_usd: 100 } ])
    report(fund: gap, quarter: Date.new(2026, 3, 31))
    report(fund: gap)
    result = summaries(fetch)
    expect(result.fetch(latest.cik).fetch("period_of_report")).to eq(current.iso8601)
    expect(result.fetch(earlier.cik).fetch("period_of_report")).to eq(prior.iso8601)
    expect(BigDecimal(result.fetch(earlier.cik).fetch(field))).to eq(0)
    expect(result.fetch(gap.cik).fetch("unavailable_reason")).to eq("no_prior_report")
    explicit = summaries(fetch(period: prior.iso8601))
    expect(explicit.fetch(latest.cik)).to include("period_of_report" => prior.iso8601, "unavailable_reason" => "no_prior_report")
    expect(explicit.fetch(gap.cik)).to include("unavailable_reason" => "no_current_report", "prior_complete" => true)
  end

  it "preserves unknowns for incomplete, empty, notice, future and absent portfolios" do
    bad, zero, notice, future, absent = 5.times.map { create(:institutional_filer) }
    pair(bad, rows: [ {}, { cusip: "594918104", value_usd: nil } ])
    pair(zero, rows: [])
    pair(notice, rows: [], submission_type: "13F-NT", report_type: "13F NOTICE")
    pair(future, quarter: Date.new(2026, 12, 31))
    results = summaries(fetch)
    expect(results.fetch(bad.cik)).to include(field => nil, "unavailable_reason" => "incomplete_current_portfolio")
    expect(results.fetch(zero.cik)).to include(field => nil, "unavailable_reason" => "zero_current_portfolio_value", "current_complete" => true)
    expect(results.fetch(notice.cik)).to include(field => nil, "unavailable_reason" => "no_effective_current_holdings", "current_source_scope" => "observed_reports")
    expect(results.fetch(future.cik).fetch("unavailable_reason")).to eq("future_report_period")
    expect(results.fetch(absent.cik)).to include(field => nil, "unavailable_reason" => "no_current_report", "period_of_report" => nil)
    expect(fetch("min_#{field}" => "0").fetch("data")).to eq([])
  end

  [ "", "-" ].each do |direction|
    it "paginates #{direction}turnover through known ties and nulls with snapshot bounds" do
      a, b, missing = 3.times.map { create(:institutional_filer) }
      first = pair(a)
      pair(b)
      report(fund: missing)
      sort = "#{direction}#{field}"
      body = fetch(sort:, limit: 1)
      ids = body.fetch("data").pluck("cik")
      report(fund: a, amendment_type: "RESTATEMENT", filed_at: Time.current, rows: [ { cusip: "594918104" } ])
      create(:institutional_holding, institutional_report: first, value_reported: 999)
      report(fund: missing, quarter: prior)
      pair(create(:institutional_filer))
      while body.dig("meta", "next_cursor")
        body = fetch(sort:, limit: 1, cursor: body.dig("meta", "next_cursor"))
        ids.concat(body.fetch("data").pluck("cik"))
      end
      expect(ids).to eq(direction.empty? ? [ a.cik, b.cik, missing.cik ] : [ b.cik, a.cik, missing.cik ])
      expect(body.fetch("meta")).to include("total_count" => 3, "has_more" => false)
      expect(body.dig("data", 0, "reported_allocation_turnover", "unavailable_reason")).to eq("no_prior_report")
    end
  end

  it "redacts default old Free inputs, permits Pro and invalidates turnover cursors after downgrade" do
    fund = create(:institutional_filer)
    pair(fund, quarter: Date.new(2025, 9, 30))
    result = summaries(fetch).fetch(fund.cik)
    expect(result).to include("unavailable_reason" => "history_restricted", field => nil, "current_sources" => [], "prior_sources" => [],
      "current_complete" => nil, "prior_complete" => nil, "period_of_report" => nil, "prior_period_of_report" => nil, "accession" => nil)
    expect(fetch("min_#{field}" => "0").fetch("data")).to eq([])
    with_billing_config do
      pair(create(:institutional_filer), quarter: Date.new(2025, 9, 30))
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      body = fetch(period: "2025-09-30", sort: field, limit: 1)
      expect(BigDecimal(body.dig("data", 0, "reported_allocation_turnover", field))).to eq(0)
      apply_billing_event(id: "evt_directory_turnover_canceled", snapshot: billing_snapshot(status: "canceled"), type: "customer.subscription.deleted")
      get api_v1_funds_path, params: { period: "2025-09-30", sort: field, limit: 1, cursor: body.dig("meta", "next_cursor") }
      expect(response).to have_http_status(:bad_request)
      expect_documented_response(path: "/funds")
      get api_v1_funds_path, params: { period: "2025-09-30", sort: field }
      expect(response).to have_http_status(:payment_required)
    end
  end

  it "rejects malformed/out-of-range percentages and changed cursor filters without writes or HTTP" do
    pair(create(:institutional_filer))
    before = [ Filing.count, InstitutionalReport.count, InstitutionalHolding.count ]
    [ { "min_#{field}" => "-1" }, { "max_#{field}" => "100.000000000001" }, { "min_#{field}" => "101" },
      { "min_#{field}" => "1e2" }, { "max_#{field}" => "NaN" }, { "min_#{field}" => [ "1" ] },
      { "min_#{field}" => "50", "max_#{field}" => "49" }, { sort: "#{field}; SELECT 1" } ].each do |parameters|
      get api_v1_funds_path, params: parameters
      expect(response).to have_http_status(:bad_request), parameters.inspect
      expect_documented_response(path: "/funds")
    end
    expect([ Filing.count, InstitutionalReport.count, InstitutionalHolding.count ]).to eq(before)
    pair(create(:institutional_filer))
    before = [ Filing.count, InstitutionalReport.count, InstitutionalHolding.count ]
    body = fetch(sort: field, limit: 1)
    get api_v1_funds_path, params: { sort: field, limit: 1, cursor: body.dig("meta", "next_cursor"), "min_#{field}" => "0" }
    expect(response).to have_http_status(:bad_request)
    expect([ Filing.count, InstitutionalReport.count, InstitutionalHolding.count ]).to eq(before)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "keeps database round trips constant as more funds are compared" do
    pair(create(:institutional_filer))
    measure = lambda do
      queries = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        queries << payload[:sql] if payload[:sql].match?(/\ASELECT/i) && payload[:name] != "SCHEMA" && !payload[:cached]
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { fetch(sort: field) }
      queries.length
    end
    baseline = measure.call
    5.times { pair(create(:institutional_filer), rows: [ { cusip: "594918104" } ]) }
    expect(measure.call).to eq(baseline)
  end
end
