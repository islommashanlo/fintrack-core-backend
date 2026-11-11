# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 dashboard" do
  include ApiAccounts
  include InstitutionalReadHelpers
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }
  let(:user) { create(:user, password: "password123") }

  def data = response.parsed_body.fetch("data")
  def meta = response.parsed_body.fetch("meta")

  def follow(type, key, owner: user, **attributes)
    create(:follow, user: owner, target_type: type, target_key: key, skip_default_alert_rule: true, **attributes)
  end

  def trade(at: 1.day.ago, issuer: "0000000123", ticker: "EXMP", **attributes)
    filing = create(:filing, filed_at: at, issuer_cik: issuer, issuer_ticker: ticker)
    create(:insider_transaction, filing:, **attributes)
  end

  def cluster(count:, issuer:, ticker:)
    count.times.map do |index|
      trade(issuer:, ticker:, insider_cik: format("%010d", index + 900), shares: 10, price: 20)
    end
  end

  it "requires authentication and marks successful and failed responses private" do
    get api_v1_dashboard_path
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    api_login(user)
    get api_v1_dashboard_path, params: { user_id: user.id }
    expect(response).to have_http_status(:bad_request)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "returns a factual empty dashboard without creating data, jobs or provider requests" do
    api_login(user)
    before = [ Filing.count, Follow.count, InstitutionalReport.count, enqueued_jobs.size ]
    get api_v1_dashboard_path
    expect(response).to have_http_status(:ok)
    expect(data.fetch("summary")).to eq("form4_filings" => 0, "insider_transactions" => 0,
      "institutional_reports" => 0, "watchlist_items" => 0, "watchlist_activity_events" => 0, "cluster_windows" => 0)
    expect(data.dig("top_clusters", "data")).to eq([])
    expect(data.dig("watchlist_activity", "data")).to eq([])
    expect(data.dig("top_unusual", "meta")).to include("available" => false, "total_count" => nil,
      "unavailable_reason" => "scoring_not_active", "limit" => 1, "truncated" => false)
    expect(meta).to include("scoring_available" => false, "market_movers_available" => false,
      "latest_filed_at" => nil, "disclaimer" => FilingsIntel::DISCLAIMER)
    expect(meta.fetch("window")).to eq("days" => 30, "date_from" => "2026-10-13", "date_to" => "2026-11-11", "timezone" => "UTC")
    expect(data.fetch("upcoming_deadlines").sole).to include("due_date" => "2026-11-16", "days_remaining" => 5,
      "period_of_report" => "2026-09-30", "timezone" => "America/New_York")
    expect([ Filing.count, Follow.count, InstitutionalReport.count, enqueued_jobs.size ]).to eq(before)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "counts visible source filings and reports while resolving amendments and joint-owner copies for transaction counts" do
    original = trade(at: 5.days.ago)
    amendment = create(:filing, form_type: "4/A", filed_at: 2.days.ago, amends_accession_no: original.accession_no)
    create(:insider_transaction, filing: amendment, transaction_code: "S")
    canonical = trade(at: 3.days.ago)
    create(:insider_transaction, filing: canonical.filing, txn_seq: canonical.txn_seq, owner_seq: 2, insider_cik: "0000000999")
    trade(at: 40.days.ago)
    trade(at: 1.day.from_now)
    trade.filing.update!(parse_status: "failed")
    fund = create(:institutional_filer)
    create_13f(fund:, period: Date.new(2026, 9, 30), filed_at: 2.days.ago)
    create_13f(fund:, period: Date.new(2026, 9, 30), filed_at: 1.day.ago, submission_type: "13F-NT", report_type: "13F NOTICE")
    create_13f(fund:, filed_at: 1.hour.ago, status: "failed")
    create_13f(fund:, filed_at: 1.day.from_now)
    api_login(user)
    get api_v1_dashboard_path
    expect(data.fetch("summary")).to include("form4_filings" => 3, "insider_transactions" => 2, "institutional_reports" => 2)
    expect(meta.fetch("latest_filed_at")).to eq(1.day.ago.as_json)
  end

  it "scopes activity to the current user's active watchlist, matching co-owners and funds without duplicates" do
    canonical = trade
    create(:insider_transaction, filing: canonical.filing, txn_seq: canonical.txn_seq, owner_seq: 2, insider_cik: "0000000789")
    fund = create(:institutional_filer)
    prior = create_13f(fund:, period: Date.new(2026, 6, 30))
    current = create_13f(fund:, period: Date.new(2026, 9, 30), filed_at: 2.days.ago)
    create(:institutional_holding, institutional_report: prior, shares: 100, value_usd: 1000)
    create(:institutional_holding, institutional_report: current, shares: 150, value_usd: 1500)
    follow("Insider", "0000000789")
    follow("Ticker", "EXMP")
    follow("InstitutionalFiler", fund.cik)
    other_trade = trade(ticker: "OTHER", issuer: "0000000555")
    other = create(:user, email_address: "dashboard-other@example.com", password: "password123")
    follow("Ticker", "OTHER", owner: other)
    follow("Insider", other_trade.insider_cik, removed_at: 1.hour.ago)
    follow("Ticker", "FUTURE", followed_at: 1.hour.from_now)
    api_login(user)
    get api_v1_dashboard_path
    section = data.fetch("watchlist_activity")
    expect(section.fetch("data").pluck("source")).to eq(%w[insider institutional])
    expect(section.fetch("data").first.fetch("reporting_owners").pluck("insider_cik")).to include("0000000789")
    expect(section.fetch("data").last.dig("position_change", "change_type")).to eq("added")
    expect(section.fetch("data")).to all(include("accession", "sec_url", "filed_at", "ingested_at", "data_age_days"))
    expect(section.fetch("data").pluck("accession")).not_to include(other_trade.accession_no)
    expect(data.fetch("summary")).to include("watchlist_items" => 3, "watchlist_activity_events" => 2)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "ranks cluster windows by distinct insider count and exposes reusable continuation cursors for both sections" do
    cluster(count: 3, issuer: "0000000111", ticker: "THREE")
    cluster(count: 5, issuer: "0000000222", ticker: "FIVE")
    cluster(count: 4, issuer: "0000000333", ticker: "FOUR")
    follow("Ticker", "FIVE")
    api_login(user)
    get api_v1_dashboard_path, params: { limit: "1" }
    clusters, watchlist = data.values_at("top_clusters", "watchlist_activity")
    expect(clusters.fetch("data").sole).to include("insider_count" => 5, "total_value" => "1000.0", "sources" => be_present)
    expect(clusters.dig("meta", "total_count")).to eq(3)
    expect(watchlist.dig("meta", "total_count")).to eq(5)
    expect(clusters.dig("meta", "as_of")).to eq(meta.fetch("as_of"))
    get api_v1_insider_clusters_path, params: clusters.dig("meta", "filters").merge(
      sort: clusters.dig("meta", "sort"), limit: "1", cursor: clusters.dig("meta", "next_cursor"))
    expect(response).to have_http_status(:ok)
    expect(data.sole.fetch("insider_count")).to eq(4)
    get api_v1_activity_path, params: watchlist.dig("meta", "filters").merge(
      sort: watchlist.dig("meta", "sort"), limit: "1", cursor: watchlist.dig("meta", "next_cursor"))
    expect(response).to have_http_status(:ok)
    expect(data.sole.fetch("id")).not_to eq(watchlist.fetch("data").sole.fetch("id"))
    other = create(:user, email_address: "cursor-other@example.com", password: "password123")
    api_login(other)
    get api_v1_activity_path, params: watchlist.dig("meta", "filters").merge(
      sort: watchlist.dig("meta", "sort"), cursor: watchlist.dig("meta", "next_cursor"))
    expect(response).to have_http_status(:bad_request)
  end

  it "uses inclusive UTC calendar windows and acceptance dates rather than transaction dates" do
    included = trade(at: 6.days.ago.beginning_of_day, transaction_date: 2.years.ago.to_date)
    excluded = trade(at: 7.days.ago, transaction_date: Date.current)
    follow("Ticker", "EXMP")
    api_login(user)
    get api_v1_dashboard_path, params: { days: "7" }
    expect(data.dig("watchlist_activity", "data").pluck("accession")).to eq([ included.accession_no ])
    expect(data.dig("summary", "form4_filings")).to eq(1)
    get api_v1_dashboard_path, params: { days: "90" }
    expect(data.dig("watchlist_activity", "data").pluck("accession")).to contain_exactly(included.accession_no, excluded.accession_no)
  end

  it "keeps unknown cluster totals null when a reported price is missing or suspect" do
    rows = cluster(count: 3, issuer: "0000000111", ticker: "PARTIAL")
    rows.first.update!(price_suspect: true)
    rows.last.update!(price: nil)
    api_login(user)
    get api_v1_dashboard_path
    expect(data.dig("top_clusters", "data").sole).to include("total_value" => nil,
      "known_value_subtotal" => "200.0", "transactions_without_usable_price" => 2)
    expect(rows.first.reload.price).to eq(20.to_d)
  end

  it "reports unavailable scoring with server-side Free and verified Pro preview limits" do
    with_billing_config do
      api_login(user)
      get api_v1_dashboard_path
      expect(data.dig("top_unusual", "meta", "limit")).to eq(1)
      bind_billing_customer(user)
      apply_billing_event
      get api_v1_dashboard_path, params: { limit: "3" }
      expect(data.dig("top_unusual", "meta", "limit")).to eq(3)
      expect(data.dig("top_unusual", "data")).to eq([])
      apply_billing_event(id: "evt_dashboard_canceled", snapshot: billing_snapshot(status: "canceled"), type: "customer.subscription.deleted")
      get api_v1_dashboard_path, params: { limit: "10" }
      expect(data.dig("top_unusual", "meta", "limit")).to eq(1)
      expect(meta.fetch("scoring_available")).to be(false)
    end
  end

  it "uses one set of ingestion ID ceilings across the sections" do
    follow("Ticker", "EXMP")
    added = nil
    allow(Api::V1::InsiderClustersQuery).to receive(:new).and_wrap_original do |method, **arguments|
      added ||= trade
      method.call(**arguments)
    end
    api_login(user)
    get api_v1_dashboard_path
    expect(data.dig("summary", "form4_filings")).to eq(0)
    expect(data.dig("watchlist_activity", "data")).to eq([])
    get api_v1_dashboard_path
    expect(data.dig("summary", "form4_filings")).to eq(1)
    expect(data.dig("watchlist_activity", "data").sole.fetch("accession")).to eq(added.accession_no)
  end

  it "keeps the due date visible until the end of its Eastern calendar day" do
    api_login(user)
    travel_to Time.utc(2026, 11, 17, 2)
    get api_v1_dashboard_path
    expect(data.fetch("upcoming_deadlines").sole).to include("due_date" => "2026-11-16", "days_remaining" => 0)
    travel_to Time.utc(2026, 11, 17, 5)
    get api_v1_dashboard_path
    expect(data.fetch("upcoming_deadlines").sole).to include("due_date" => "2027-02-16", "days_remaining" => 91)
  end

  it "rejects unsupported filters, invalid windows, structured values and oversized sections" do
    api_login(user)
    [ { days: "0" }, { days: "365" }, { days: "07" }, { days: [ "7" ] }, { limit: "0" },
      { limit: "11" }, { limit: "1;SELECT" }, { cursor: "ignored" }, { sort: "value" }, { user_id: user.id } ].each do |values|
      get api_v1_dashboard_path, params: values
      expect(response).to have_http_status(:bad_request)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  it "keeps SQL query counts bounded as the number of displayed owners and filings grows" do
    trade
    follow("Ticker", "EXMP")
    api_login(user)
    measure = lambda do
      queries = []
      subscriber = lambda { |*args| queries << args.last[:sql] unless args.last[:name] == "SCHEMA" || args.last[:cached] }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { get api_v1_dashboard_path, params: { limit: "10" } }
      expect(response).to have_http_status(:ok)
      queries.count { |sql| sql.match?(/\ASELECT|\AWITH/) }
    end
    baseline = measure.call
    cluster(count: 8, issuer: "0000000123", ticker: "EXMP")
    expect(measure.call).to be <= baseline + 2
  end
end
