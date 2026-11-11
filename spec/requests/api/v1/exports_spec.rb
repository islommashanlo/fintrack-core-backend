# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 CSV exports" do
  include ApiAccounts
  include InstitutionalReadHelpers
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }
  let(:user) { create(:user, password: "password123") }
  let(:fund) { create(:institutional_filer) }

  def grant_pro(account = user)
    allow(PlanCatalog).to receive(:for_user).and_call_original
    allow(PlanCatalog).to receive(:for_user).with(account).and_return("pro")
  end

  def export(dataset = "insider-transactions", **values)
    get api_v1_export_path(dataset), params: values
  end

  # All cells are quoted. This reader also handles quoted commas and line breaks.
  def rows
    cells = response.body.scan(/"((?:[^"]|"")*)"(?:,|\r\n)/).flatten.map { |cell| cell.gsub('""', '"') }
    headers = Api::V1::CsvDocument::COLUMNS.fetch(@dataset || "insider-transactions")
    expect(cells.shift(headers.length)).to eq(headers)
    cells.each_slice(headers.length).map { |values| headers.zip(values).to_h }
  end

  def report(quarter = Date.new(2026, 9, 30), **values)
    create_13f(fund:, period: quarter, filed_at: 2.days.ago, **values)
  end

  it "requires sign-in and server-verified Pro for every dataset with private JSON errors" do
    export
    expect(response).to have_http_status(:unauthorized)
    expect(response.media_type).to eq("application/json")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    api_login(user)
    Api::V1::ExportQuery::PARAMETERS.each_key do |dataset|
      export(dataset, plan: "pro")
      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body).to eq("code" => "PRO_REQUIRED", "feature" => "csv_export", "limit" => 0)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["Content-Disposition"]).to be_nil
    end
  end

  it "exports existing transaction filters, all reporting owners, precision, flags and source times" do
    grant_pro
    api_login(user)
    filing = create(:filing, filed_at: 1.day.ago, accepted_at: 1.day.ago, ingested_at: 12.hours.ago)
    first = create(:insider_transaction, filing:, shares: BigDecimal("12.500000000001"), price: 20, is_director: true)
    second = create(:insider_transaction, filing:, owner_seq: 2, price_suspect: true, price_suspect_reason: "Check source", price: 999)
    create(:insider_transaction, filing:, transaction_code: "A")
    create(:insider_transaction, filing: create(:filing, filed_at: 1.day.from_now))
    counts = [ Filing.count, InsiderTransaction.count, InstitutionalHolding.count ]
    export(type: "open_market", ticker: filing.issuer_ticker.downcase)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    expect(response.headers["Content-Disposition"]).to include('attachment;', 'filingsintel-insider-transactions-20261111T120000Z.csv')
    expect(rows.pluck("id")).to eq([ second.id.to_s, first.id.to_s ])
    expect(rows.last).to include("shares" => "12.500000000001", "value" => "250.00000000002", "direction" => "purchase",
      "issuer.cik" => filing.issuer_cik, "accession" => filing.accession_no, "sec_url" => filing.sec_url,
      "filed_at" => 1.day.ago.iso8601(6), "accepted_at" => 1.day.ago.iso8601(6),
      "ingested_at" => 12.hours.ago.iso8601(6), "data_age_days" => "1", "disclaimer" => FilingsIntel::DISCLAIMER)
    expect(rows.first).to include("owner_sequence" => "2", "price" => "999.0", "price_suspect" => "true", "value" => "")
    expect(response.headers).to include("X-Export-Row-Count" => "2", "X-Export-Total-Count" => "2",
      "X-Export-Has-More" => "false", "X-Export-Row-Limit" => "1000", "Cache-Control" => "no-store")
    expect([ Filing.count, InsiderTransaction.count, InstitutionalHolding.count ]).to eq(counts)
    expect(WebMock).not_to have_requested(:any, /./)
    expect(enqueued_jobs).to be_empty
  end

  it "exports effective reported holding rows including options without enrichment or row aggregation" do
    grant_pro
    api_login(user)
    @dataset = "fund-holdings"
    original = report
    create(:institutional_holding, institutional_report: original, shares: 999)
    restatement = report(amendment_type: "RESTATEMENT", filed_at: 1.day.ago)
    first = create(:institutional_holding, institutional_report: restatement, value_reported: 17,
      value_unit: "thousands", value_usd: 17000, suspect: true)
    second = create(:institutional_holding, institutional_report: restatement, put_call: "PUT", value_usd: nil)
    addition = report(amendment_type: "NEW HOLDINGS", filed_at: 1.hour.ago)
    third = create(:institutional_holding, institutional_report: addition)
    export(@dataset, cik: fund.cik, sort: "row_sequence")
    expect(rows.pluck("id")).to eq([ first, second, third ].map { |row| row.id.to_s })
    expect(rows.first).to include("fund.cik" => fund.cik, "value_reported" => "17.0", "value_unit" => "thousands",
      "value_usd" => "17000.0", "suspect" => "true", "accession" => restatement.filing.accession_no)
    expect(rows.second).to include("put_call" => "PUT", "value_usd" => "")
    export(@dataset, cik: fund.cik, put_call: "PUT")
    expect(rows.pluck("id")).to eq([ second.id.to_s ])
    expect(original.institutional_holdings.sole.shares).to eq(999)
  end

  it "exports derived changes with complete current/prior source lists and old baseline evidence" do
    grant_pro
    api_login(user)
    @dataset = "fund-changes"
    previous = report(Date.new(2025, 9, 30))
    current = report(Date.new(2025, 12, 31))
    create(:institutional_holding, institutional_report: previous, shares: 100, value_usd: 1000)
    create(:institutional_holding, institutional_report: current, shares: 75, value_usd: 750)
    export(@dataset, cik: fund.cik, period: "2025-12-31", change_type: "reduced")
    expect(response).to have_http_status(:ok)
    expect(rows.sole).to include("fund.cik" => fund.cik, "change_type" => "reduced", "shares_delta" => "-25.0",
      "value_usd_delta" => "-250.0", "prior_period_of_report" => "2025-09-30")
    expect(JSON.parse(rows.sole.fetch("current_sources")).sole.fetch("accession")).to eq(current.filing.accession_no)
    expect(JSON.parse(rows.sole.fetch("prior_sources")).sole.fetch("accession")).to eq(previous.filing.accession_no)
  end

  it "bounds downloads and uses actor-bound export cursors that exclude later inserts" do
    grant_pro
    api_login(user)
    filing = create(:filing, filed_at: 1.day.ago)
    first = create(:insider_transaction, filing:)
    second = create(:insider_transaction, filing:)
    export(limit: "1")
    expect(rows.pluck("id")).to eq([ second.id.to_s ])
    cursor, as_of = response.headers.values_at("X-Export-Next-Cursor", "X-Export-As-Of")
    create(:insider_transaction, filing:)
    export(limit: "1", cursor:)
    expect(rows.pluck("id")).to eq([ first.id.to_s ])
    expect(response.headers).to include("X-Export-Total-Count" => "2", "X-Export-Has-More" => "false", "X-Export-As-Of" => as_of)
    get api_v1_insider_transactions_path, params: { limit: "1", cursor: }
    expect(response).to have_http_status(:bad_request)
    export(limit: "1", cursor:, direction: "sale")
    expect(response).to have_http_status(:bad_request)
    another = create(:user, email_address: "another-export@example.com", password: "password123")
    grant_pro(another)
    api_login(another)
    export(limit: "1", cursor:)
    expect(response).to have_http_status(:bad_request)
  end

  it "pins default fund quarters, keeps public list limits and rejects cursors from JSON or another export" do
    grant_pro
    api_login(user)
    @dataset = "fund-holdings"
    selected = report(Date.new(2026, 6, 30))
    2.times { create(:institutional_holding, institutional_report: selected) }
    pending = report(status: "pending")
    create(:institutional_holding, institutional_report: pending)
    export(@dataset, cik: fund.cik, limit: "1", sort: "row_sequence")
    cursor = response.headers.fetch("X-Export-Next-Cursor")
    pending.update!(status: "parsed")
    export(@dataset, cik: fund.cik, limit: "1", sort: "row_sequence", cursor:)
    expect(rows.sole.fetch("period_of_report")).to eq("2026-06-30")
    export("fund-changes", cik: fund.cik, limit: "1", sort: "cusip", cursor:)
    expect(response).to have_http_status(:bad_request)
    get holdings_api_v1_fund_path(fund.cik), params: { limit: "1", period: "2026-06-30", sort: "row_sequence" }
    json_cursor = response.parsed_body.dig("meta", "next_cursor")
    export(@dataset, cik: fund.cik, limit: "1", period: "2026-06-30", sort: "row_sequence", cursor: json_cursor)
    expect(response).to have_http_status(:bad_request)
    get holdings_api_v1_fund_path(fund.cik), params: { limit: "101" }
    expect(response).to have_http_status(:bad_request)
    get api_v1_insider_transactions_path, params: { limit: "101" }
    expect(response).to have_http_status(:bad_request)
  end

  it "returns at most 1000 rows by default and provides the remaining rows through a signed continuation" do
    grant_pro
    api_login(user)
    transaction = create(:insider_transaction)
    template = transaction.attributes.except("id")
    InsiderTransaction.insert_all!(1000.times.map { |index| template.merge("txn_seq" => transaction.txn_seq + index + 1) })
    export
    expect(response).to have_http_status(:ok)
    expect(rows.size).to eq(1000)
    expect(response.headers).to include("X-Export-Row-Count" => "1000", "X-Export-Total-Count" => "1001", "X-Export-Has-More" => "true")
    cursor = response.headers.fetch("X-Export-Next-Cursor")
    export(cursor:)
    expect(rows.pluck("id")).to eq([ transaction.id.to_s ])
    expect(response.headers).to include("X-Export-Row-Count" => "1", "X-Export-Has-More" => "false")
    expect(response.headers["X-Export-Next-Cursor"]).to be_nil
  end

  it "uses verified entitlements on every request including cursor continuations after cancellation" do
    with_billing_config do
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      2.times { create(:insider_transaction) }
      export(limit: "1")
      expect(response).to have_http_status(:ok)
      cursor = response.headers.fetch("X-Export-Next-Cursor")
      apply_billing_event(id: "evt_export_canceled", snapshot: billing_snapshot(status: "canceled"), type: "customer.subscription.deleted")
      export(limit: "1", cursor:)
      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body.fetch("feature")).to eq("csv_export")
    end
  end

  it "returns a header-only CSV for empty reports and leaves malformed inputs as private JSON errors" do
    grant_pro
    api_login(user)
    @dataset = "fund-holdings"
    report
    export(@dataset, cik: fund.cik)
    expect(response).to have_http_status(:ok)
    expect(rows).to eq([])
    [ { cik: "1" }, { cik: fund.cik, period: "2026-09-29" }, { cik: fund.cik, limit: "1001" },
      { cik: fund.cik, cusip: "' OR 1=1" }, { cik: fund.cik, sort: "name;drop" }, { cik: fund.cik, limit: [ "1" ] },
      { cik: fund.cik, maximum_limit: "10000" } ].each do |values|
      export(@dataset, **values)
      expect(response).to have_http_status(:bad_request), values.inspect
      expect(response.media_type).to eq("application/json")
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["Content-Disposition"]).to be_nil
    end
    export("unknown")
    expect(response).to have_http_status(:not_found)
  end

  it "throttles exports independently while keeping normal reads available" do
    grant_pro
    api_login(user)
    10.times { ApiRateLimiter.check!(scope: "export_user", identifier: user.id, limit: 10, window: 1.minute) }
    export
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.headers["Retry-After"].to_i).to be_between(1, 60)
    get api_v1_insider_transactions_path
    expect(response).to have_http_status(:ok)
  end

  it "returns JSON on byte-limit failures and exposes pagination headers only to the configured frontend origin" do
    grant_pro
    api_login(user)
    create(:insider_transaction, insider_name: "=SUM(A1)")
    with_frontend_origin("https://app.example.com") do
      get api_v1_export_path("insider-transactions"), headers: { "Origin" => "https://app.example.com" }
      expect(response.body).to include('"\'=SUM(A1)"')
      expect(response.headers["Access-Control-Expose-Headers"]).to include("Content-Disposition", "X-Export-Next-Cursor", "X-Export-Row-Count")
      get api_v1_export_path("insider-transactions"), headers: { "Origin" => "https://untrusted.example" }
      expect(response.headers["Access-Control-Expose-Headers"]).to be_nil
    end
    stub_const("Api::V1::CsvDocument::MAX_BYTES", 10)
    export
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body.dig("error", "code")).to eq("EXPORT_TOO_LARGE")
    expect(response.headers["Content-Disposition"]).to be_nil
  end
end
