# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 screener" do
  include ApiAccounts
  include InstitutionalReadHelpers
  around { |example| travel_to(Time.utc(2026, 11, 10, 20)) { example.run } }

  def run_screen(entity: "companies", filters: [], **options)
    post api_v1_screener_run_path, params: { entity:, filters:, **options }, headers: api_headers, as: :json
  end

  def data
    response.parsed_body.fetch("data")
  end

  def meta
    response.parsed_body.fetch("meta")
  end

  def transaction(cik: "0000000123", name: "Example Corp", ticker: "EXMP", at: 1.day.ago, filing: nil, **attributes)
    filing ||= create(:filing, issuer_cik: cik, issuer_name: name, issuer_ticker: ticker, filed_at: at)
    create(:insider_transaction, filing:, **attributes)
  end

  def fund_report(fund: create(:institutional_filer), positions: [ {} ], **attributes)
    report = create_13f(fund:, **attributes)
    rows = positions.map do |position|
      create(:institutional_holding, institutional_report: report, **position)
    end
    report.update!(table_entry_total: rows.length, table_value_total: rows.sum(&:value_reported))
    report
  end

  it "requires CSRF protection even for anonymous POST queries and does not write data" do
    transaction
    with_api_csrf_protection do
      run_screen
      expect(response).to have_http_status(:forbidden)
      api_csrf
      expect { run_screen }.not_to change(Filing, :count)
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  it "screens companies using complete canonical non-derivative aggregates and source provenance" do
    primary = transaction(is_director: true, shares: 100, price: 10)
    transaction(filing: primary.filing, owner_seq: 2, txn_seq: primary.txn_seq, insider_cik: "0000000789", shares: 100, price: 10)
    transaction(shares: 25, price: 20, transaction_code: "S", acquired_disposed: "D")
    transaction(shares: 500, transaction_code: "A")
    transaction(shares: 500, security_table: "derivative")
    transaction(cik: "0000000999", name: "Other Company", ticker: "OTHER", shares: 1)
    run_screen(filters: [ { field: "purchase_count", operator: "gte", value: 1 },
                          { field: "net_open_market_value", operator: "between", value: [ 400, 600 ] } ])
    expect(response).to have_http_status(:ok)
    expect(data.length).to eq(1)
    expect(data.sole).to include("entity" => "companies", "cik" => primary.issuer_cik, "ticker" => "EXMP", "window_days" => 90)
    expect(data.sole.fetch("metrics")).to include("purchase_count" => 1, "sale_count" => 1, "open_market_count" => 2,
      "purchase_value" => "1000.0", "sale_value" => "500.0", "net_open_market_value" => "500.0", "insider_count" => 1)
    expect(data.sole).to include("accession", "sec_url", "filed_at", "ingested_at", "data_age_days")
    expect(meta).to include("total_count" => 1, "truncated" => false, "feature" => "screener_results", "preview_limit" => 3)
  end

  it "keeps joint owners as separate insider identities with the latest disclosed role" do
    primary = transaction(shares: 100, is_officer: true)
    other = transaction(filing: primary.filing, owner_seq: 2, txn_seq: primary.txn_seq,
      insider_cik: "0000000789", insider_name: "Other Owner", is_director: true)
    run_screen(entity: "insiders", filters: [ { field: "latest_is_director", operator: "eq", value: true } ])
    expect(data.pluck("cik")).to eq([ other.insider_cik ])
    expect(data.sole.fetch("metrics")).to include("purchase_count" => 1, "purchase_value" => "1000.0", "issuer_count" => 1)
    expect(data.sole.fetch("latest_role")).to include("latest_role_issuer_cik" => primary.issuer_cik)
    run_screen(entity: "insiders", filters: [ { field: "latest_is_director", operator: "eq", value: false } ])
    expect(data.pluck("cik")).to eq([ primary.insider_cik ])
  end

  it "keeps incomplete monetary totals null and supports explicit null filters" do
    transaction
    transaction(price: nil)
    transaction(price: 100_000, price_suspect: true)
    run_screen(filters: [ { field: "purchase_value", operator: "is_null" } ])
    expect(data.sole.fetch("metrics")).to include("purchase_count" => 3, "purchase_value" => nil,
      "sale_value" => "0.0", "net_open_market_value" => nil, "transactions_without_usable_value" => 2)
    run_screen(filters: [ { field: "purchase_value", operator: "gte", value: 0 } ])
    expect(data).to eq([])
    run_screen(filters: [ { field: "sale_value", operator: "eq", value: 0 } ])
    expect(data.length).to eq(1)
  end

  it "uses acceptance-time windows and treats an empty observed window as zero activity" do
    old = transaction(at: 100.days.ago)
    old.update!(transaction_date: 1.day.ago.to_date)
    transaction(cik: "0000000999", name: "Recent", at: 5.days.ago, transaction_date: 300.days.ago.to_date)
    transaction(cik: "0000000888", name: "Boundary", at: 30.days.ago)
    run_screen(window_days: 30, filters: [ { field: "purchase_count", operator: "eq", value: 0 } ])
    expect(data.pluck("cik")).to contain_exactly(old.issuer_cik, "0000000888")
    expect(data).to all(include("metrics" => include("purchase_value" => "0.0", "net_open_market_value" => "0.0")))
    run_screen(window_days: 365, filters: [ { field: "purchase_count", operator: "eq", value: 1 } ])
    expect(meta.fetch("total_count")).to eq(3)
  end

  it "applies text, identity, date and array filters as bound literal data" do
    transaction(name: "Literal %_ Company's '); DROP TABLE users; --")
    transaction(cik: "0000000999", name: "Literal Plain", ticker: "PLAIN")
    run_screen(filters: [ { field: "name", operator: "contains", value: "%_" },
                          { field: "ticker", operator: "in", value: [ "exmp" ] },
                          { field: "last_filed_on", operator: "between", value: [ "2026-11-08", "2026-11-10" ] } ])
    expect(data.pluck("cik")).to eq([ "0000000123" ])
    run_screen(filters: [ { field: "name", operator: "contains", value: "'); DROP TABLE users; --" } ])
    expect(data.length).to eq(1)
    expect(User.count).to eq(0)
    run_screen(filters: [ { field: "name", operator: "starts_with", value: "literal plain" },
                          { field: "cik", operator: "not_eq", value: "0000000123" } ])
    expect(data.pluck("ticker")).to eq([ "PLAIN" ])
  end

  %w[name -name cik -cik purchase_value -purchase_value].each do |sort|
    it "limits #{sort} to the same first three matches across cursor pages" do
      5.times { |i| transaction(cik: format("%010d", i + 100), name: "Same Name", shares: i + 1) }
      run_screen(sort:, page: { limit: 1 })
      expected = sort.start_with?("-") ? %w[0000000104 0000000103 0000000102] : %w[0000000100 0000000101 0000000102]
      ids = data.pluck("cik")
      cursor = meta.fetch("next_cursor")
      transaction(cik: "0000000001", name: "Late Insert", at: 2.days.ago)
      2.times do
        run_screen(sort:, limit: 1, cursor:)
        expect(response).to have_http_status(:ok)
        ids.concat(data.pluck("cik"))
        cursor = meta.fetch("next_cursor")
      end
      expect(ids).to eq(expected)
      expect(meta).to include("total_count" => 5, "truncated" => true, "has_more" => false, "next_cursor" => nil)
      run_screen(sort:, limit: 100)
      expect(data.length).to eq(3)
    end
  end

  it "keeps null sort values last in both directions and exact large decimal boundaries" do
    transaction(cik: "0000000100", shares: BigDecimal("9223372036854775808000.000001"), price: 1)
    transaction(cik: "0000000101", shares: BigDecimal("9223372036854775808000.000002"), price: 1)
    transaction(cik: "0000000102", price: nil)
    run_screen(sort: "-purchase_value", limit: 1)
    expect(data.pluck("cik")).to eq([ "0000000101" ])
    cursor = meta.fetch("next_cursor")
    run_screen(sort: "-purchase_value", limit: 1, cursor:)
    expect(data.pluck("cik")).to eq([ "0000000100" ])
    expect(data.sole.dig("metrics", "purchase_value")).to eq("9223372036854775808000.000001")
    run_screen(sort: "purchase_value")
    expect(data.pluck("cik")).to eq(%w[0000000100 0000000101 0000000102])
  end

  it "preserves the initial filing snapshot when a backdated amendment is ingested between pages" do
    first = transaction(cik: "0000000100", name: "First")
    original = transaction(cik: "0000000101", name: "Second")
    run_screen(limit: 1)
    cursor = meta.fetch("next_cursor")
    amendment = create(:filing, issuer_cik: original.issuer_cik, issuer_name: "Second", form_type: "4/A",
      amends_accession_no: original.accession_no, filed_at: 1.hour.ago)
    create(:insider_transaction, filing: amendment, shares: 300)
    run_screen(limit: 1, cursor:)
    expect(data.sole.fetch("accession")).to eq(original.accession_no)
    expect(data.sole.dig("metrics", "purchase_value")).to eq("1000.0")
    run_screen(filters: [ { field: "cik", operator: "eq", value: original.issuer_cik } ])
    expect(data.sole.fetch("accession")).to eq(amendment.accession_no)
    expect(data.sole.dig("metrics", "purchase_value")).to eq("3000.0")
    expect(first.reload.shares).to eq(100)
  end

  it "screens effective fund portfolios and aggregates repeated keys without calling the total AUM" do
    fund = create(:institutional_filer)
    original = fund_report(fund:, positions: [ { shares: 100 } ])
    replacement = fund_report(fund:, amendment_type: "RESTATEMENT", filed_at: original.filing.filed_at + 1.day,
      positions: [ { shares: 60 }, { shares: 60 }, { shares: 25, put_call: "CALL" } ])
    addition = fund_report(fund:, amendment_type: "NEW HOLDINGS", filed_at: replacement.filing.filed_at + 1.day)
    run_screen(entity: "funds", filters: [ { field: "portfolio_value_usd", operator: "gte", value: 300 } ])
    expect(response).to have_http_status(:ok)
    expect(data.sole.fetch("metrics")).to include("holding_row_count" => 4, "position_count" => 2,
      "portfolio_value_usd" => "400.0", "suspect" => false)
    expect(data.sole).to include("accession" => addition.filing.accession_no, "source_filing_count" => 2,
      "period_of_report" => "2026-06-30", "window_days" => nil)
    expect(data.sole.fetch("metrics")).not_to have_key("aum")
  end

  it "leaves notice-only or incomplete fund portfolios unknown while preserving source data" do
    notice = fund_report(submission_type: "13F-NT", positions: [])
    unknown = fund_report(positions: [ { value_usd: nil } ])
    broken = fund_report
    broken.update!(table_entry_total: 2)
    run_screen(entity: "funds", sort: "cik", filters: [ { field: "portfolio_value_usd", operator: "is_null" } ])
    expect(meta.fetch("total_count")).to eq(3)
    result = data.index_by { |row| row.fetch("cik") }
    expect(result.fetch(notice.institutional_filer.cik).fetch("metrics")).to include("holding_row_count" => nil, "position_count" => nil)
    expect(result.fetch(unknown.institutional_filer.cik).dig("metrics", "portfolio_value_usd")).to be_nil
    expect(result.fetch(broken.institutional_filer.cik).dig("metrics", "suspect")).to be(true)
  end

  it "records a complete empty fund portfolio as zero rather than an unknown notice" do
    report = fund_report(positions: [])
    run_screen(entity: "funds", filters: [ { field: "portfolio_value_usd", operator: "eq", value: 0 } ])
    expect(data.sole.fetch("cik")).to eq(report.institutional_filer.cik)
    expect(data.sole.fetch("metrics")).to include("holding_row_count" => 0, "position_count" => 0, "portfolio_value_usd" => "0.0")
  end

  it "keeps normalized fund totals and report versions stable across cursor pages" do
    funds = 4.times.map { |i| create(:institutional_filer, name: "Fund #{i}") }
    reports = funds.map do |fund|
      fund_report(fund:, cover_value_unit: "thousands",
        positions: [ { value_reported: 100, value_unit: "thousands", value_usd: 100_000 } ])
    end
    run_screen(entity: "funds", limit: 1)
    cursor = meta.fetch("next_cursor")
    replacement = fund_report(fund: funds[1], amendment_type: "RESTATEMENT", filed_at: 1.day.ago,
      cover_value_unit: "thousands", positions: [ { value_reported: 200, value_unit: "thousands", value_usd: 200_000 } ])
    run_screen(entity: "funds", limit: 1, cursor:)
    expect(data.sole).to include("accession" => reports[1].filing.accession_no)
    expect(data.sole.dig("metrics", "portfolio_value_usd")).to eq("100000.0")
    run_screen(entity: "funds", filters: [ { field: "cik", operator: "eq", value: funds[1].cik } ])
    expect(data.sole).to include("accession" => replacement.filing.accession_no)
    expect(data.sole.dig("metrics", "portfolio_value_usd")).to eq("200000.0")
    expect(reports[1].institutional_holdings.sole.value_reported).to eq(100)
  end

  it "does not expose pending, failed, undated or future filing-derived entities" do
    [ { parse_status: "pending" }, { parse_status: "failed" }, { filed_at: nil }, { filed_at: 1.day.from_now } ].each do |attributes|
      transaction(filing: create(:filing, **attributes))
    end
    failed = fund_report
    failed.filing.update!(parse_status: "failed")
    %w[companies insiders funds].each do |entity|
      run_screen(entity:)
      expect(data).to eq([])
    end
  end

  it "keeps authenticated users on Free and rejects client-supplied entitlements" do
    5.times { |i| transaction(cik: format("%010d", i + 100)) }
    user = create(:user, password: "password123")
    api_login(user)
    run_screen(limit: 100)
    expect(data.length).to eq(3)
    expect(meta).to include("preview_limit" => 3, "truncated" => true)
    run_screen(plan: "pro")
    expect(response).to have_http_status(:bad_request)
  end

  it "allows an unlimited server entitlement and invalidates its cursor after a downgrade" do
    5.times { |i| transaction(cik: format("%010d", i + 100)) }
    allow(PlanCatalog).to receive(:limit_for).with(nil, :screener_results).and_return(nil)
    run_screen(limit: 2)
    first_cursor = meta.fetch("next_cursor")
    ids = data.pluck("cik")
    cursor = first_cursor
    2.times do
      run_screen(limit: 2, cursor:)
      ids.concat(data.pluck("cik"))
      cursor = meta.fetch("next_cursor")
    end
    expect(ids.uniq.length).to eq(5)
    expect(meta).to include("total_count" => 5, "truncated" => false, "preview_limit" => nil, "has_more" => false)
    allow(PlanCatalog).to receive(:limit_for).with(nil, :screener_results).and_return(3)
    run_screen(limit: 2, cursor: first_cursor)
    expect(response).to have_http_status(:bad_request)
  end

  it "binds cursors to query, identity and entitlement and rejects expired or altered tokens" do
    4.times { |i| transaction(cik: format("%010d", i + 100)) }
    run_screen(limit: 1)
    cursor = meta.fetch("next_cursor")
    [ { entity: "insiders" }, { filters: [ { field: "purchase_count", operator: "gte", value: 0 } ] },
      { sort: "-name" }, { window_days: 30 }, { cursor: "#{cursor}x" } ].each do |options|
      run_screen(limit: 1, cursor:, **options)
      expect(response).to have_http_status(:bad_request)
    end
    user = create(:user, password: "password123")
    api_login(user)
    run_screen(cursor:)
    expect(response).to have_http_status(:bad_request)
    run_screen(limit: 1)
    user_cursor = meta.fetch("next_cursor")
    travel 25.hours
    run_screen(cursor: user_cursor)
    expect(response).to have_http_status(:bad_request)
  end

  it "hydrates filing provenance with one query for the page" do
    3.times { |i| transaction(cik: format("%010d", i + 100)) }
    reads = []
    subscriber = ->(_name, _start, _finish, _id, payload) { reads << payload[:sql] if payload[:sql].match?(/\ASELECT "filings"\.\*/) }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { run_screen }
    expect(data.length).to eq(3)
    expect(reads.length).to eq(1)
  end

  it "returns JSON validation errors for unsupported fields, sort SQL and malformed filter shapes" do
    [ { filters: [ { field: "score", operator: "gte", value: 80 } ] },
      { sort: "name; SELECT 1" }, { filters: { where: "TRUE" } }, { page: { offset: 3 } },
      { filters: [ { field: "purchase_value", operator: "gte", value: "NaN" } ] },
      { filters: [ { field: "purchase_count", operator: "eq", value: "9223372036854775808" } ] },
      { filters: [ { field: "last_filed_on", operator: "eq", value: "0000-01-01" } ] } ].each do |options|
      run_screen(**options)
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq("INVALID_PARAMETER")
    end
  end
end
