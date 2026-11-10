# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 insider clusters" do
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 10, 12)) { example.run } }

  def data
    response.parsed_body.fetch("data")
  end

  def meta
    response.parsed_body.fetch("meta")
  end

  def trade(cik:, at:, code: "P", ticker: "EXMP", issuer: "0000000123", filing: nil, **attributes)
    filing ||= create(:filing, filed_at: at, issuer_cik: issuer, issuer_ticker: ticker)
    create(:insider_transaction, filing:, insider_cik: cik, insider_name: "Example #{cik}",
      transaction_code: code, shares: 10, price: 20, **attributes)
  end

  def three_trades(code: "P", ticker: "EXMP", issuer: "0000000123")
    [ "0000000901", "0000000902", "0000000903" ].each_with_index.map do |cik, index|
      trade(cik:, code:, ticker:, issuer:, at: (3 - index).days.ago)
    end
  end

  it "finds three distinct first-listed insiders with precise totals and every source filing" do
    trades = three_trades
    get api_v1_insider_clusters_path
    expect(response).to have_http_status(:ok)
    expect(data.length).to eq(1)
    row = data.first
    expect(row).to include("direction" => "purchase", "window_days" => 14, "insider_count" => 3,
      "transaction_count" => 3, "total_value" => "600.0", "known_value_subtotal" => "600.0",
      "transactions_without_usable_price" => 0, "accession" => trades.last.accession_no,
      "sec_url" => trades.last.filing.sec_url, "data_age_days" => 1,
      "window_end" => trades.last.filing.filed_at.as_json, "window_start" => (trades.last.filing.filed_at - 14.days).as_json)
    expect(row.fetch("transaction_ids")).to eq(trades.map(&:id))
    expect(row.fetch("activity_ids")).to eq(trades.map { |transaction| "insider_#{transaction.id}" })
    expect(row.fetch("insiders").pluck("cik")).to eq(trades.map(&:insider_cik))
    expect(row.fetch("sources").pluck("accession")).to contain_exactly(*trades.map(&:accession_no))
    expect(row.fetch("id")).to match(/\Acluster_[a-f0-9]{64}\z/)
    expect(meta).to include("window_days" => 14, "minimum_insiders" => 3, "total_count" => 1)
  end

  it "does not qualify repeated transactions from only one or two insiders" do
    [ "0000000901", "0000000902", "0000000901", "0000000902" ].each do |cik|
      trade(cik:, at: 1.day.ago)
    end
    get api_v1_insider_clusters_path
    expect(data).to eq([])
  end

  it "does not count joint reporting-owner copies as independent insiders or inflate total value" do
    first = trade(cik: "0000000901", at: 1.day.ago, txn_seq: 1)
    [ "0000000902", "0000000903" ].each_with_index do |cik, index|
      trade(cik:, at: 1.day.ago, filing: first.filing, txn_seq: 1, owner_seq: index + 2)
    end
    get api_v1_insider_clusters_path
    expect(data).to eq([])

    trade(cik: "0000000904", at: 1.day.ago)
    trade(cik: "0000000905", at: 1.day.ago)
    get api_v1_insider_clusters_path
    expect(data.sole).to include("insider_count" => 3, "transaction_count" => 3, "total_value" => "600.0")
  end

  it "uses an exclusive 14-day start and inclusive acceptance timestamp at the window end" do
    ending = 1.day.ago
    trade(cik: "0000000901", at: ending - 14.days)
    trade(cik: "0000000902", at: ending - 7.days)
    trade(cik: "0000000903", at: ending)
    get api_v1_insider_clusters_path
    expect(data).to eq([])
    trade(cik: "0000000904", at: ending - 14.days + 1.second)
    get api_v1_insider_clusters_path, params: { date_from: ending.to_date.iso8601, date_to: ending.to_date.iso8601 }
    expect(data.sole.fetch("insider_count")).to eq(3)
    expect(data.sole.fetch("window_end")).to eq(ending.as_json)
  end

  it "uses reported acceptance dates, not trade dates, and excludes other directions, issuers and tables" do
    trade(cik: "0000000901", at: 1.day.ago, transaction_date: 2.years.ago.to_date)
    trade(cik: "0000000902", at: 1.day.ago, transaction_date: 2.years.ago.to_date)
    trade(cik: "0000000903", at: 1.day.ago, code: "S")
    trade(cik: "0000000903", at: 1.day.ago, code: "A")
    trade(cik: "0000000903", at: 1.day.ago, security_table: "derivative")
    trade(cik: "0000000903", at: 1.day.ago, issuer: "0000000999")
    get api_v1_insider_clusters_path
    expect(data).to eq([])
    trade(cik: "0000000903", at: 1.day.ago, transaction_date: 2.years.ago.to_date)
    get api_v1_insider_clusters_path
    expect(data.sole.fetch("transaction_count")).to eq(3)
  end

  it "mirrors sale clusters independently and supports exact ticker and direction filters" do
    three_trades
    three_trades(code: "S", ticker: "EXMP.A", issuer: "0000000999")
    get api_v1_insider_clusters_path
    expect(data.pluck("direction")).to contain_exactly("purchase", "sale")
    get api_v1_insider_clusters_path, params: { direction: "sale", ticker: "exmp.a", issuer_cik: "0000000999" }
    expect(data.sole.fetch("direction")).to eq("sale")
    get api_v1_insider_clusters_path, params: { direction: "sale", ticker: "EXMP" }
    expect(data).to eq([])
  end

  it "retains counts when values are suspect or missing and leaves the full value unknown" do
    trade(cik: "0000000901", at: 1.day.ago)
    suspect = trade(cik: "0000000902", at: 1.day.ago, price: 100_000, price_suspect: true)
    trade(cik: "0000000903", at: 1.day.ago, price: nil)
    get api_v1_insider_clusters_path
    expect(data.sole).to include("insider_count" => 3, "total_value" => nil, "known_value_subtotal" => "200.0",
      "transactions_without_usable_price" => 2)
    get api_v1_insider_clusters_path, params: { min_value: "0" }
    expect(data).to eq([])
    expect(suspect.reload.price).to eq(100_000.to_d)
  end

  it "resolves effective amendments and does not let failed or future filings establish a cluster" do
    rows = three_trades
    original = rows.last
    amendment = create(:filing, form_type: "4/A", filed_at: 1.hour.ago, amends_accession_no: original.accession_no)
    create(:insider_transaction, filing: amendment, insider_cik: original.insider_cik, transaction_code: "S")
    pending = create(:filing, filed_at: 1.hour.ago, parse_status: "failed")
    create(:insider_transaction, filing: pending, insider_cik: "0000000904")
    future = create(:filing, filed_at: 1.day.from_now)
    create(:insider_transaction, filing: future, insider_cik: "0000000905")
    get api_v1_insider_clusters_path
    expect(data).to eq([])
  end

  it "emits a new rolling window at each distinct qualifying acceptance time rather than merging a long chain" do
    3.times { |i| trade(cik: format("%010d", 901 + i), at: (30 - i * 7).days.ago) }
    get api_v1_insider_clusters_path
    expect(data).to eq([])
    trade(cik: "0000000904", at: 9.days.ago)
    get api_v1_insider_clusters_path
    expect(data).to eq([])
    trade(cik: "0000000905", at: 3.days.ago)
    get api_v1_insider_clusters_path
    expect(data.sole.fetch("insider_count")).to eq(3)
    expect(data.sole.fetch("window_end")).to eq(3.days.ago.as_json)
  end

  it "defaults to recent windows and can retrieve a historical date range with the preceding membership context" do
    [ "0000000901", "0000000902", "0000000903" ].each_with_index do |cik, index|
      trade(cik:, at: Time.utc(2025, 11, 1 + index))
    end
    get api_v1_insider_clusters_path
    expect(data).to eq([])
    get api_v1_insider_clusters_path, params: { date_to: "2025-11-30" }
    expect(data.length).to eq(1)
    get api_v1_insider_clusters_path, params: { date_from: "2025-11-03", date_to: "2025-11-03" }
    expect(data.sole.fetch("transaction_count")).to eq(3)
  end

  it "uses one database query to hydrate source filings for a page" do
    three_trades
    trade(cik: "0000000904", at: 1.hour.ago)
    reads = []
    subscriber = ->(_name, _start, _finish, _id, payload) { reads << payload[:sql] if payload[:sql].match?(/SELECT "filings"\.\*/) }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { get api_v1_insider_clusters_path }
    expect(data.length).to eq(2)
    expect(reads.length).to eq(1)
  end

  it "allows raising the insider threshold and applies the complete-value filter inclusively" do
    three_trades
    trade(cik: "0000000904", at: 1.hour.ago)
    get api_v1_insider_clusters_path, params: { min_insiders: 4, min_value: "800.0" }
    expect(data.sole).to include("insider_count" => 4, "total_value" => "800.0")
    expect(meta).to include("minimum_insiders" => 4, "definition_minimum_insiders" => 3)
    get api_v1_insider_clusters_path, params: { min_insiders: 4, min_value: "800.01" }
    expect(data).to eq([])
  end

  it "paginates missing totals after complete totals in either direction" do
    three_trades
    three_trades(issuer: "0000000999").last.update!(price: nil)
    %w[total_value -total_value].each do |sort|
      get api_v1_insider_clusters_path, params: { sort:, limit: 1 }
      expect(data.sole.fetch("total_value")).to eq("600.0")
      cursor = meta.fetch("next_cursor")
      get api_v1_insider_clusters_path, params: { sort:, limit: 1, cursor: }
      expect(data.sole.fetch("total_value")).to be_nil
      expect(meta.fetch("has_more")).to be(false)
    end
  end

  %w[window_end -window_end insider_count -insider_count transaction_count -transaction_count total_value -total_value].each do |sort|
    it "paginates #{sort} ties without repeats and excludes later arrivals and amendments" do
      three_trades
      extra = trade(cik: "0000000904", at: 1.hour.ago)
      get api_v1_insider_clusters_path, params: { sort:, limit: 1 }
      first = data.sole.fetch("id")
      cursor = meta.fetch("next_cursor")
      amended = create(:filing, form_type: "4/A", filed_at: 1.minute.ago, amends_accession_no: extra.accession_no)
      create(:insider_transaction, filing: amended, insider_cik: extra.insider_cik, transaction_code: "S")
      trade(cik: "0000000905", at: 1.minute.ago)
      get api_v1_insider_clusters_path, params: { sort:, limit: 1, cursor: }
      expect(response).to have_http_status(:ok)
      expect(meta).to include("total_count" => 2, "has_more" => false)
      expect(data.sole.fetch("id")).not_to eq(first)
    end
  end

  it "requires sign-in for private clusters and matches a co-owner without exposing another user's follows" do
    trades = three_trades
    create(:insider_transaction, filing: trades.last.filing, insider_cik: "0000000999", owner_seq: 2, txn_seq: trades.last.txn_seq)
    get api_v1_insider_clusters_path, params: { watchlist_only: true }
    expect(response).to have_http_status(:unauthorized)
    user = create(:user, password: "password123")
    create(:follow, user:, target_type: "Insider", target_key: "0000000999")
    api_login(user)
    get api_v1_insider_clusters_path, params: { watchlist_only: true }
    expect(data.sole.fetch("insider_count")).to eq(3)
    expect(response.headers["Cache-Control"]).to eq("no-store")

    other = create(:user, email_address: "other@example.com", password: "password123")
    api_login(other)
    get api_v1_insider_clusters_path, params: { watchlist_only: true }
    expect(data).to eq([])
  end

  it "rejects malformed filters, lower thresholds, altered and expired cursors" do
    three_trades
    trade(cik: "0000000904", at: 1.hour.ago)
    get api_v1_insider_clusters_path, params: { limit: 1 }
    cursor = meta.fetch("next_cursor")
    [ { min_insiders: "2" }, { min_insiders: "3.5" }, { min_insiders: "1001" }, { ticker: "EXMP%" },
      { issuer_cik: "123" }, { direction: "invalid" }, { min_value: "NaN" }, { date_from: "2026-02-30" },
      { direction: [ "purchase" ] }, { sort: "window_end; SELECT 1" }, { cursor: "#{cursor}x" },
      { cursor:, direction: "sale" } ].each do |values|
      get api_v1_insider_clusters_path, params: values
      expect(response).to have_http_status(:bad_request), values.inspect
    end
    travel 25.hours
    get api_v1_insider_clusters_path, params: { cursor: }
    expect(response).to have_http_status(:bad_request)
  end
end
