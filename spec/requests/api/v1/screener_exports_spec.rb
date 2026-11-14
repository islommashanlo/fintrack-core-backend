# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Pro screener CSV exports" do
  include ApiAccounts
  include InstitutionalReadHelpers
  include OpenapiResponses
  around { |example| travel_to(Time.utc(2026, 11, 13, 12)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }

  def pro(account = user)
    allow(PlanCatalog).to receive(:for_user).and_call_original
    allow(PlanCatalog).to receive(:for_user).with(account).and_return("pro")
  end

  def export(entity: "companies", **options)
    @dataset = "screener-#{entity}"
    post api_v1_screener_export_path, params: { entity:, **options }, headers: api_headers, as: :json
  end

  def rows
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    cells = response.body.scan(/"((?:[^"]|"")*)"(?:,|\r\n)/).flatten.map { |cell| cell.gsub('""', '"') }
    columns = Api::V1::CsvDocument::COLUMNS.fetch(@dataset)
    expect(cells.shift(columns.length)).to eq(columns)
    cells.each_slice(columns.length).map { |values| columns.zip(values).to_h }
  end

  def trade(cik: "0000000123", name: "Example Company", **attributes)
    filing = create(:filing, issuer_cik: cik, issuer_name: name, filed_at: 1.day.ago)
    create(:insider_transaction, filing:, **attributes)
  end

  def report(fund:, period:, holdings: [ {} ], **attributes)
    source = create_13f(fund:, period:, filed_at: 2.days.ago, **attributes)
    items = holdings.map { |values| create(:institutional_holding, institutional_report: source, **values) }
    source.update!(table_entry_total: items.length, table_value_total: items.sum(&:value_reported))
    source
  end

  it "requires authentication, CSRF and server-side Pro access with private JSON errors" do
    api_csrf
    export
    expect(response).to have_http_status(:unauthorized)
    expect_documented_response(path: "/screener/export", method: :post)
    api_login(user)
    export(plan: "pro")
    expect(response).to have_http_status(:payment_required)
    expect(response.parsed_body).to eq("code" => "PRO_REQUIRED", "feature" => "csv_export", "limit" => 0)
    expect_documented_response(path: "/screener/export", method: :post)
    pro
    post api_v1_screener_export_path, params: { entity: "companies" }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "exports the same typed company metrics and provenance as JSON with exact decimals and formula safety" do
    pro
    api_login(user)
    selected = trade(name: "=SUM(A1),\"Example\"", shares: BigDecimal("12.500000000001"), price: 20)
    create(:insider_transaction, filing: selected.filing, insider_cik: "0000000789", owner_seq: 2, txn_seq: selected.txn_seq, shares: selected.shares, price: 20)
    trade(cik: "0000000999", shares: 1, price: nil)
    filters = [ { field: "purchase_value", operator: "gte", value: "250.00000000002" } ]
    post api_v1_screener_run_path, params: { entity: "companies", filters: }, headers: api_headers, as: :json
    json = response.parsed_body.fetch("data").sole
    export(filters:)
    csv = rows.sole
    expect(csv).to include("name" => "'=SUM(A1),\"Example\"", "metrics.purchase_value" => json.dig("metrics", "purchase_value"),
      "metrics.purchase_count" => "1", "accession" => json.fetch("accession"), "sec_url" => json.fetch("sec_url"),
      "cik" => selected.issuer_cik, "disclaimer" => FilingsIntel::DISCLAIMER)
    expect(response.headers).to include("X-Export-Row-Count" => "1", "X-Export-Total-Count" => "1", "X-Export-Row-Limit" => "1000", "Cache-Control" => "no-store")
    expect(response.headers["Content-Disposition"]).to include("filingsintel-screener-companies-20261113T120000Z.csv")
    expect(WebMock).not_to have_requested(:any, /./)
    expect(enqueued_jobs).to be_empty
  end

  it "keeps joint-owner insider identities distinct and preserves roles, false values and unknown totals" do
    pro
    api_login(user)
    primary = trade(is_officer: true, officer_title: "Director, Operations", price: nil)
    other = create(:insider_transaction, filing: primary.filing, owner_seq: 2, txn_seq: primary.txn_seq,
      insider_cik: "0000000789", is_director: true, price: 20, shares: 10)
    export(entity: "insiders", filters: [ { field: "latest_is_director", operator: "eq", value: false } ])
    expect(rows.sole).to include("cik" => primary.insider_cik, "metrics.latest_is_director" => "false", "metrics.latest_is_officer" => "true",
      "metrics.purchase_value" => "", "latest_role.officer_title" => "Director, Operations", "metrics.transactions_without_usable_value" => "1")
    export(entity: "insiders", filters: [ { field: "latest_is_director", operator: "eq", value: true } ])
    expect(rows.sole.fetch("cik")).to eq(other.insider_cik)
  end

  it "exports complete old fund metrics, report labels, turnover and evidence using the JSON serializer" do
    pro
    api_login(user)
    fund = create(:institutional_filer)
    report(fund:, period: Date.new(2025, 6, 30))
    report(fund:, period: Date.new(2025, 9, 30), holdings: [ { value_reported: 50, value_usd: 50 },
      { value_reported: 50, value_usd: 50, investment_discretion: "DFND" }, { cusip: "594918104" } ])
    post api_v1_screener_run_path, params: { entity: "funds" }, headers: api_headers, as: :json
    json = response.parsed_body.fetch("data").sole
    export(entity: "funds")
    csv = rows.sole
    expect(csv).to include("cik" => fund.cik, "period_of_report" => "2025-09-30", "metrics.holding_row_count" => "3",
      "metrics.position_count" => "2", "metrics.portfolio_value_usd" => json.dig("metrics", "portfolio_value_usd"),
      "metrics.reported_allocation_turnover_percent" => json.dig("metrics", "reported_allocation_turnover_percent"))
    expect(JSON.parse(csv.fetch("reported_allocation_turnover"))).to eq(json.fetch("reported_allocation_turnover"))
    expect(JSON.parse(csv.fetch("report_types"))).to eq(json.fetch("report_types"))
    expect(JSON.parse(csv.fetch("report_type_sources"))).to eq(json.fetch("report_type_sources"))
  end

  it "leaves incomplete and missing normalized fund values blank instead of inferring zero" do
    pro
    api_login(user)
    fund = create(:institutional_filer)
    report(fund:, period: Date.new(2026, 9, 30), holdings: [ { value_usd: nil } ])
    export(entity: "funds", filters: [ { field: "portfolio_value_usd", operator: "is_null" } ])
    expect(rows.sole).to include("metrics.portfolio_value_usd" => "", "metrics.reported_allocation_turnover_percent" => "")
    export(entity: "funds", filters: [ { field: "portfolio_value_usd", operator: "eq", value: 0 } ])
    expect(rows).to be_empty
  end

  it "binds continuations to the actor, normalized filters, entity and export context while excluding later inserts" do
    pro
    api_login(user)
    3.times { |i| trade(cik: format("%010d", 100 + i)) }
    export(sort: "cik", limit: 1)
    expect(rows.sole.fetch("cik")).to eq("0000000100")
    cursor = response.headers.fetch("X-Export-Next-Cursor")
    trade(cik: "0000000103")
    export(sort: "cik", page: { limit: 2, cursor: })
    expect(rows.pluck("cik")).to eq(%w[0000000101 0000000102])
    expect(response.headers).to include("X-Export-Total-Count" => "3", "X-Export-Has-More" => "false")
    [ { entity: "insiders" }, { filters: [ { field: "purchase_count", operator: "gte", value: 1 } ] } ].each do |options|
      export(sort: "cik", cursor:, **options)
      expect(response).to have_http_status(:bad_request)
    end
    post api_v1_screener_run_path, params: { entity: "companies", sort: "cik", cursor: }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
    other = create(:user, email_address: "other-screen-export@example.com", password: "password123")
    pro(other)
    api_login(other)
    export(sort: "cik", cursor:)
    expect(response).to have_http_status(:bad_request)
  end

  it "rejects JSON and other export cursors without changing JSON limits or Free previews" do
    pro
    api_login(user)
    4.times { |i| trade(cik: format("%010d", 100 + i)) }
    post api_v1_screener_run_path, params: { entity: "companies", limit: 1 }, headers: api_headers, as: :json
    cursor = response.parsed_body.dig("meta", "next_cursor")
    export(limit: 1, cursor:)
    expect(response).to have_http_status(:bad_request)
    get api_v1_export_path("insider-transactions"), params: { limit: "1" }
    other_cursor = response.headers.fetch("X-Export-Next-Cursor")
    export(limit: 1, cursor: other_cursor)
    expect(response).to have_http_status(:bad_request)
    post api_v1_screener_run_path, params: { entity: "companies", limit: 101 }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
    allow(PlanCatalog).to receive(:for_user).with(user).and_return("free")
    post api_v1_screener_run_path, params: { entity: "companies" }, headers: api_headers, as: :json
    expect(response.parsed_body.fetch("data").size).to eq(3)
    expect(response.parsed_body.fetch("meta")).to include("truncated" => true, "total_count" => 4)
  end

  it "keeps continuation tokens bounded for the largest accepted filter lists" do
    pro
    api_login(user)
    name = "A" * 200
    2.times { |i| trade(cik: format("%010d", 100 + i), name:) }
    choices = [ name, *19.times.map { |i| "Other #{i}".ljust(200, "x") } ]
    filters = 20.times.map { { field: "name", operator: "in", value: choices } }
    export(sort: "cik", filters:, limit: 1)
    cursor = response.headers.fetch("X-Export-Next-Cursor")
    expect(cursor.bytesize).to be <= Api::V1::ScreenerInputRules::MAX_CURSOR_BYTES
    export(sort: "cik", filters:, limit: 1, cursor:)
    expect(rows.sole.fetch("cik")).to eq("0000000101")
  end

  it "keeps original source evidence across pages when a backdated amendment arrives later" do
    pro
    api_login(user)
    trade(cik: "0000000100", name: "First")
    original = trade(cik: "0000000101", name: "Second")
    export(limit: 1)
    cursor = response.headers.fetch("X-Export-Next-Cursor")
    amendment = create(:filing, issuer_cik: original.issuer_cik, issuer_name: "Second amended", form_type: "4/A",
      filed_at: 12.hours.ago, amends_accession_no: original.accession_no)
    create(:insider_transaction, filing: amendment, transaction_code: "S")
    export(limit: 1, cursor:)
    expect(rows.sole).to include("accession" => original.accession_no, "metrics.purchase_count" => "1", "metrics.sale_count" => "0")
  end

  it "returns a thousand-row page with a signed continuation and no query-time source writes" do
    pro
    api_login(user)
    template = create(:filing, issuer_cik: "0000000100", filed_at: 1.day.ago).attributes.except("id")
    Filing.insert_all!(1000.times.map do |index|
      template.merge("accession_no" => format("0009999999-26-%06d", index + 100_000), "issuer_cik" => format("%010d", index + 101))
    end)
    before = Filing.count
    export(sort: "cik")
    expect(rows.size).to eq(1000)
    expect(response.headers).to include("X-Export-Total-Count" => "1001", "X-Export-Has-More" => "true")
    cursor = response.headers.fetch("X-Export-Next-Cursor")
    export(sort: "cik", cursor:)
    expect(rows.size).to eq(1)
    expect(response.headers["X-Export-Next-Cursor"]).to be_nil
    expect(Filing.count).to eq(before)
  end

  it "rechecks verified entitlement on every continuation after subscription cancellation" do
    with_billing_config do
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      2.times { |i| trade(cik: format("%010d", 100 + i)) }
      export(limit: 1)
      cursor = response.headers.fetch("X-Export-Next-Cursor")
      apply_billing_event(id: "evt_screen_export_canceled", snapshot: billing_snapshot(status: "canceled"), type: "customer.subscription.deleted")
      export(limit: 1, cursor:)
      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body.fetch("feature")).to eq("csv_export")
      expect(response.headers["Content-Disposition"]).to be_nil
    end
  end

  it "rejects malformed inputs with JSON errors and returns a header-only CSV when no entity matches" do
    pro
    api_login(user)
    [ { entity: "unsupported" }, { limit: 1001 }, { limit: 1, page: { limit: 1 } }, { filters: "raw SQL" },
      { filters: [ { field: "name;drop", operator: "eq", value: "x" } ] }, { sort: "name;drop" }, { maximum_limit: 9999 } ].each do |values|
      export(**values)
      expect(response).to have_http_status(:bad_request), values.inspect
      expect_documented_response(path: "/screener/export", method: :post)
      expect(response.headers["Content-Disposition"]).to be_nil
    end
    export
    expect(rows).to be_empty
    expect(response.body.lines.size).to eq(1)
  end

  it "retains byte-limit failures and credentialed CORS pagination headers" do
    pro
    api_login(user)
    trade
    with_frontend_origin("https://app.example.com") do
      post api_v1_screener_export_path, params: { entity: "companies" }, headers: api_headers.merge("Origin" => "https://app.example.com"), as: :json
      expect(response).to have_http_status(:ok)
      expect(response.headers["Access-Control-Expose-Headers"]).to include("X-Export-Next-Cursor", "Content-Disposition")
    end
    stub_const("Api::V1::CsvDocument::MAX_BYTES", 10)
    export
    expect(response).to have_http_status(:unprocessable_entity)
    expect_documented_response(path: "/screener/export", method: :post)
    expect(response.parsed_body.dig("error", "code")).to eq("EXPORT_TOO_LARGE")
    expect(response.headers["Content-Disposition"]).to be_nil
  end

  it "shares export throttling with existing CSV downloads while leaving JSON reads available" do
    pro
    api_login(user)
    10.times { get api_v1_export_path("insider-transactions") }
    export
    expect(response).to have_http_status(:too_many_requests)
    expect_documented_response(path: "/screener/export", method: :post)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    post api_v1_screener_run_path, params: { entity: "companies" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
  end
end
