# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reported allocation turnover in fund screens" do
  include OpenapiResponses
  include ApiAccounts
  include InstitutionalReadHelpers
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

  def pair(fund, rows: [ {} ], quarter: current)
    report(fund:, quarter: (quarter << 3).end_of_quarter)
    report(fund:, quarter:, rows:)
  end

  def run_screen(filters: [], **options)
    post api_v1_screener_run_path, params: { entity: "funds", filters:, **options }, headers: api_headers, as: :json
  end

  def screen(filters: [], **options)
    run_screen(filters:, **options)
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/screener/run", method: :post)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    response.parsed_body
  end

  def condition(operator, value = nil) = { field:, operator:, value: }

  it "screens inclusive percentages and returns matching metrics and independent source evidence" do
    zero, half, full = 3.times.map { create(:institutional_filer) }
    pair(zero)
    pair(half, rows: [ { value_reported: 50 }, { cusip: "594918104", value_reported: 50 } ])
    pair(full, rows: [ { cusip: "594918104" } ])
    body = screen(filters: [ condition("between", [ "9", "100" ]) ], sort: field)
    expect(body.fetch("data").pluck("cik")).to eq([ half.cik, full.cik ])
    row = body.fetch("data").first
    expect(row.fetch("metrics").fetch(field)).to eq("50.0")
    expect(row.fetch("reported_allocation_turnover")).to include(field => "50.0", "status" => "available",
      "current_complete" => true, "prior_complete" => true)
    get api_v1_fund_path(half.cik)
    expect(response.parsed_body.dig("data", "reported_allocation_turnover")).to eq(row.fetch("reported_allocation_turnover"))
    expect(body.fetch("meta")).to include("turnover_methodology_version" => "reported-allocation-turnover-v1",
      "turnover_baseline_policy" => "adjacent_calendar_quarter", "turnover_history_quarters" => 4, "turnover_earliest_period" => "2025-12-31")
    expect(screen(filters: [ condition("in", [ 0, 100 ]) ], sort: field).fetch("data").pluck("cik")).to eq([ zero.cik, full.cik ])
  end

  it "keeps null conditions separate from zero for missing, incomplete and zero-value inputs" do
    missing, broken, empty = 3.times.map { create(:institutional_filer) }
    report(fund: missing)
    pair(broken, rows: [ { value_usd: nil } ])
    pair(empty, rows: [])
    rows = screen(filters: [ condition("is_null") ], sort: "cik").fetch("data")
    expect(rows.pluck("cik")).to eq([ missing.cik, broken.cik, empty.cik ])
    expect(rows.map { |row| row.dig("reported_allocation_turnover", "unavailable_reason") })
      .to eq(%w[no_prior_report incomplete_current_portfolio zero_current_portfolio_value])
    expect(rows.map { |row| row.fetch("metrics").fetch(field) }).to all(be_nil)
    expect(screen(filters: [ condition("eq", 0) ]).fetch("data")).to eq([])
    expect(screen(filters: [ condition("not_eq", 0) ]).fetch("data")).to eq([])
  end

  it "retains the same three-result Free prefix across turnover cursor pages" do
    funds = [ 0, 25, 50, 75, 100 ].map do |percent|
      fund = create(:institutional_filer)
      pair(fund, rows: [ { value_reported: 100 - percent }, { cusip: "594918104", value_reported: percent } ])
      fund
    end
    body = screen(filters: [ condition("not_null") ], sort: "-#{field}", limit: 1)
    ids = body.fetch("data").pluck("cik")
    2.times do
      body = screen(filters: [ condition("not_null") ], sort: "-#{field}", limit: 1, cursor: body.dig("meta", "next_cursor"))
      ids.concat(body.fetch("data").pluck("cik"))
    end
    expect(ids).to eq(funds.last(3).reverse.map(&:cik))
    expect(body.fetch("meta")).to include("total_count" => 5, "truncated" => true, "preview_limit" => 3, "has_more" => false, "next_cursor" => nil)
  end

  it "pins report and holding ceilings across pages and keeps late baselines unknown" do
    zero, half, missing = 3.times.map { create(:institutional_filer) }
    source = pair(zero)
    pair(half, rows: [ { value_reported: 50 }, { cusip: "594918104", value_reported: 50 } ])
    report(fund: missing)
    body = screen(sort: "-#{field}", limit: 1)
    expect(body.fetch("data").sole.fetch("cik")).to eq(half.cik)
    report(fund: zero, amendment_type: "RESTATEMENT", filed_at: Time.current, rows: [ { cusip: "594918104" } ])
    create(:institutional_holding, institutional_report: source, value_reported: 999)
    report(fund: missing, quarter: prior)
    body = screen(sort: "-#{field}", limit: 1, cursor: body.dig("meta", "next_cursor"))
    expect(body.fetch("data").sole.fetch("metrics").fetch(field)).to eq("0.0")
    body = screen(sort: "-#{field}", limit: 1, cursor: body.dig("meta", "next_cursor"))
    expect(body.fetch("data").sole.fetch("reported_allocation_turnover")).to include("unavailable_reason" => "no_prior_report", field => nil, "prior_sources" => [])
  end

  it "uses the fund's adjacent quarter and resolved amendments while keeping legacy identity provenance" do
    fund = create(:institutional_filer)
    report(fund:, quarter: prior)
    current_report = report(fund:)
    amendment = report(fund:, quarter: prior, amendment_type: "RESTATEMENT", filed_at: 1.day.ago, rows: [ { cusip: "594918104" } ])
    row = screen.fetch("data").sole
    expect(row.fetch("accession")).to eq(current_report.filing.accession_no)
    expect(row.fetch("metrics").fetch(field)).to eq("100.0")
    expect(row.fetch("reported_allocation_turnover")).to include("accession" => amendment.filing.accession_no,
      "prior_period_of_report" => prior.iso8601, "current_complete" => true, "prior_complete" => true)
  end

  it "gates derived metrics for old Free periods and invalidates paid cursors after downgrade" do
    fund = create(:institutional_filer)
    old = pair(fund, quarter: Date.new(2025, 9, 30))
    row = screen.fetch("data").sole
    expect(row.fetch("metrics")).to include(field => nil, "portfolio_value_usd" => nil, "position_count" => nil, "holding_row_count" => nil, "suspect" => nil)
    expect(row.fetch("reported_allocation_turnover")).to include("unavailable_reason" => "history_restricted",
      "current_complete" => nil, "prior_complete" => nil, "current_sources" => [], "prior_sources" => [], field => nil)
    expect(row.fetch("accession")).to eq(old.filing.accession_no)
    with_billing_config do
      pair(create(:institutional_filer), quarter: Date.new(2025, 9, 30))
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      body = screen(sort: field, limit: 1)
      expect(body.fetch("data").sole.fetch("metrics").fetch(field)).to eq("0.0")
      expect(body.fetch("meta").fetch("turnover_history_quarters")).to be_nil
      apply_billing_event(id: "evt_screener_turnover_canceled", snapshot: billing_snapshot(status: "canceled"), type: "customer.subscription.deleted")
      run_screen(sort: field, limit: 1, cursor: body.dig("meta", "next_cursor"))
      expect(response).to have_http_status(:bad_request)
      expect(screen(filters: [ condition("not_null") ]).fetch("data")).to eq([])
    end
  end

  it "allows an adjacent baseline outside Free history for an accessible selected quarter" do
    fund = create(:institutional_filer)
    pair(fund, quarter: Date.new(2025, 12, 31))
    row = screen(filters: [ condition("eq", 0) ]).fetch("data").sole
    expect(row.dig("reported_allocation_turnover", "prior_period_of_report")).to eq("2025-09-30")
  end

  it "stores a Pro turnover screen and runs its normalized definition unchanged" do
    fund = create(:institutional_filer)
    pair(fund, rows: [ { cusip: "594918104" } ])
    with_billing_config do
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      post api_v1_saved_screens_path, params: { name: "Reported allocation changes", definition: {
        entity: "funds", filters: [ condition("gte", "50.000000000001") ], sort: "-#{field}" } }, headers: api_headers, as: :json
      expect(response).to have_http_status(:created)
      definition = response.parsed_body.dig("data", "definition")
      expect(definition.fetch("filters").sole.fetch("value")).to eq("50.000000000001")
      post api_v1_screener_run_path, params: definition, headers: api_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data").sole.fetch("cik")).to eq(fund.cik)
    end
  end

  it "binds fund cursors to actor, percentage conditions and sorting" do
    3.times { pair(create(:institutional_filer)) }
    body = screen(sort: field, limit: 1)
    cursor = body.dig("meta", "next_cursor")
    [ { filters: [ condition("gte", 0) ] }, { sort: "-#{field}" }, { entity: "companies" } ].each do |options|
      run_screen(sort: field, limit: 1, cursor:, **options)
      expect(response).to have_http_status(:bad_request)
    end
    api_login(create(:user, password: "password123"))
    run_screen(sort: field, limit: 1, cursor:)
    expect(response).to have_http_status(:bad_request)
  end

  it "keeps read-query round trips constant as the paid fund screen grows" do
    with_billing_config do
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      pair(create(:institutional_filer))
      measure = lambda do
        reads = []
        subscriber = lambda do |_name, _start, _finish, _id, payload|
          reads << payload[:sql] if payload[:sql].match?(/\A(?:SELECT|WITH)\b/i) && payload[:name] != "SCHEMA" && !payload[:cached]
        end
        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { screen(sort: field, limit: 100) }
        reads.length
      end
      baseline = measure.call
      5.times { pair(create(:institutional_filer)) }
      expect(measure.call).to eq(baseline)
      expect(response.parsed_body.fetch("data").length).to eq(6)
    end
  end

  it "enforces CSRF and rejects invalid, cross-entity and client-supplied entitlement inputs" do
    before = [ Filing.count, InstitutionalReport.count, InstitutionalHolding.count ]
    with_api_csrf_protection do
      run_screen(filters: [ condition("eq", 0) ])
      expect(response).to have_http_status(:forbidden)
      api_csrf
      [ { filters: [ condition("gt", 101) ] }, { filters: [ condition("eq", "0 OR 1=1") ] },
        { filters: [ condition("between", [ 50, 49 ]) ] }, { entity: "companies", sort: field },
        { entity: "insiders", filters: [ condition("gte", 0) ] }, { plan: "pro" } ].each do |parameters|
        run_screen(**parameters)
        expect(response).to have_http_status(:bad_request), parameters.inspect
      end
    end
    expect([ Filing.count, InstitutionalReport.count, InstitutionalHolding.count ]).to eq(before)
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
