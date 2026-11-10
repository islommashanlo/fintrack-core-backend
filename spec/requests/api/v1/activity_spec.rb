# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 activity" do
  include InstitutionalReadHelpers
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 10, 12)) { example.run } }

  def data
    response.parsed_body.fetch("data")
  end

  def meta
    response.parsed_body.fetch("meta")
  end

  def insider_event(issuer_ticker: "EXMP", **attributes)
    filing = create(:filing, filed_at: 2.days.ago, issuer_ticker:)
    create(:insider_transaction, filing:, **attributes)
  end

  def institutional_pair(fund: create(:institutional_filer), before: 100, after: 150, **attributes)
    prior = create_13f(fund:, period: Date.new(2026, 3, 31), filed_at: Time.utc(2026, 5, 15))
    current = create_13f(fund:)
    create(:institutional_holding, institutional_report: prior, shares: before, value_usd: before * 10, **attributes) if before
    create(:institutional_holding, institutional_report: current, shares: after, value_usd: after * 10, **attributes) if after
    [ fund, prior, current ]
  end

  it "returns a unified, chronologically ordered feed with source provenance and unavailable scores left null" do
    transaction = insider_event
    fund, prior, current = institutional_pair
    get api_v1_activity_path

    expect(response).to have_http_status(:ok)
    expect(data.pluck("source")).to eq(%w[insider institutional])
    expect(meta).to include("total_count" => 2, "scoring_available" => false, "sector_available" => false,
      "available_sources" => %w[insider institutional])
    expect(data.first).to include("id" => "insider_#{transaction.id}", "accession" => transaction.accession_no,
      "sec_url" => transaction.filing.sec_url, "direction" => "purchase", "value" => "1000.0",
      "filed_at" => transaction.filing.filed_at.as_json, "accepted_at" => transaction.filing.accepted_at.as_json,
      "ingested_at" => transaction.filing.ingested_at.as_json, "data_age_days" => 2)
    expect(data).to all(include("score" => nil, "level" => nil, "reasons" => [], "score_breakdown" => []))
    institutional = data.last
    expect(institutional).to include("fund" => { "cik" => fund.cik, "name" => fund.name }, "direction" => "increase",
      "value" => "500.0", "accession" => current.filing.accession_no)
    expect(institutional.fetch("position_change")).to include("change_type" => "added", "shares_delta" => "50.0")
    expect(institutional.fetch("position_change").fetch("comparison_sources").pluck("accession"))
      .to contain_exactly(current.filing.accession_no, prior.filing.accession_no)
  end

  it "deduplicates joint reporting owners while retaining their identities and reported roles" do
    canonical = insider_event(txn_seq: 1)
    create(:insider_transaction, filing: canonical.filing, txn_seq: 1, owner_seq: 2,
      insider_cik: "0000000789", insider_name: "Second Owner", is_officer: true)
    get api_v1_activity_path
    expect(meta.fetch("total_count")).to eq(1)
    expect(data.first.fetch("reporting_owners").pluck("insider_cik")).to eq([ canonical.insider_cik, "0000000789" ])
    expect(data.first.fetch("reporting_owners").last.dig("role", "is_officer")).to be(true)
  end

  it "filters activity by source, factual direction, type, value and acceptance date" do
    purchase = insider_event(shares: 50, price: 20)
    insider_event(transaction_code: "S", shares: 20, price: 10)
    insider_event(transaction_code: "A", price: nil)
    institutional_pair
    get api_v1_activity_path, params: { source: "insider", direction: "purchase", type: "open_market",
      min_value: "1000", date_from: "2026-11-08", date_to: "2026-11-08" }
    expect(data.pluck("id")).to eq([ "insider_#{purchase.id}" ])
    get api_v1_activity_path, params: { type: "administrative" }
    expect(data.pluck("direction")).to eq([ "other" ])
    get api_v1_activity_path, params: { source: "institutional", direction: "increase" }
    expect(data.length).to eq(1)
  end

  it "preserves suspect prices and derived flags while excluding them from feed magnitude filters" do
    transaction = insider_event(price: 100_000, price_suspect: true)
    institutional_pair(suspect: true)
    get api_v1_activity_path
    expect(data).to all(include("value" => nil))
    expect(data.first.dig("transaction", "price")).to eq("100000.0")
    expect(data.last.dig("position_change", "current_suspect")).to be(true)
    get api_v1_activity_path, params: { min_value: "0" }
    expect(data).to eq([])
    expect(transaction.reload.price).to eq(100_000.to_d)
  end

  it "requires an immediately preceding-quarter baseline and ignores notices, failed and future reports" do
    fund = create(:institutional_filer)
    lone = create_13f(fund:)
    create(:institutional_holding, institutional_report: lone)
    gap = create_13f(fund:, period: Date.new(2025, 12, 31), filed_at: Time.utc(2026, 2, 14))
    create(:institutional_holding, institutional_report: gap, shares: 200)
    notice = create_13f(fund:, period: Date.new(2026, 9, 30), submission_type: "13F-NT", report_type: "13F NOTICE")
    create(:institutional_holding, institutional_report: notice)
    failed = create_13f(fund:, period: Date.new(2026, 3, 31), status: "failed")
    create(:institutional_holding, institutional_report: failed)
    future = create_13f(fund:, period: Date.new(2026, 3, 31), filed_at: 1.day.from_now)
    create(:institutional_holding, institutional_report: future)
    get api_v1_activity_path
    expect(data).to eq([])
  end

  it "records exits against the current quarter's absence evidence and keeps option positions distinct" do
    fund, _prior, current = institutional_pair(after: nil, put_call: "PUT")
    get api_v1_activity_path
    event = data.sole
    expect(event).to include("direction" => "decrease", "value" => "1000.0", "fund" => include("cik" => fund.cik))
    expect(event.dig("position_change", "change_type")).to eq("exited")
    expect(event.dig("position_change", "put_call")).to eq("PUT")
    expect(event.fetch("position_change").fetch("current_sources").pluck("accession")).to eq([ current.filing.accession_no ])
  end

  it "dates recomputed institutional activity by the latest input filing, including a later prior-quarter restatement" do
    fund, prior, _current = institutional_pair
    restatement = create_13f(fund:, period: prior.period_of_report, filed_at: 1.day.ago, amendment_type: "RESTATEMENT")
    create(:institutional_holding, institutional_report: restatement, shares: 75, value_usd: 750)
    get api_v1_activity_path
    expect(data.sole).to include("accession" => restatement.filing.accession_no, "data_age_days" => 1,
      "occurred_at" => restatement.filing.filed_at.as_json)
    expect(data.sole.dig("position_change", "shares_delta")).to eq("75.0")
  end

  it "requires sign-in for a watchlist feed and matches co-owners, funds and mapped issuers without duplicate events" do
    canonical = insider_event(txn_seq: 1)
    create(:insider_transaction, filing: canonical.filing, txn_seq: 1, owner_seq: 2, insider_cik: "0000000789")
    fund, = institutional_pair
    map_security(cusip: "037833100", ticker: canonical.issuer_ticker)
    get api_v1_activity_path, params: { watchlist_only: true }
    expect(response).to have_http_status(:unauthorized)
    user = create(:user, password: "password123")
    create(:follow, user:, target_type: "Insider", target_key: "0000000789")
    api_login(user)
    get api_v1_activity_path, params: { watchlist_only: true }
    expect(data.pluck("source")).to eq([ "insider" ])
    create(:follow, user:, target_type: "Ticker", target_key: canonical.issuer_ticker)
    fund_follow = create(:follow, user:, target_type: "InstitutionalFiler", target_key: fund.cik)
    get api_v1_activity_path, params: { watchlist_only: true }
    expect(meta.fetch("total_count")).to eq(2)
    expect(data.pluck("source")).to contain_exactly("insider", "institutional")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    fund_follow.destroy!
    get api_v1_activity_path, params: { watchlist_only: true, source: "institutional" }
    expect(data.length).to eq(1)
    CusipSecurityMapping.update_all(status: "ambiguous")
    get api_v1_activity_path, params: { watchlist_only: true, source: "institutional" }
    expect(data).to eq([])
  end

  it "does not use another user's watchlist or infer issuer mappings from similar names" do
    insider_event
    institutional_pair
    other = create(:user, email_address: "other@example.com", password: "password123")
    create(:follow, user: other, target_type: "Ticker", target_key: "EXMP")
    user = create(:user, password: "password123")
    create(:follow, user:, target_type: "Ticker", target_key: "APPLE")
    api_login(user)
    get api_v1_activity_path, params: { watchlist_only: true }
    expect(data).to eq([])
  end

  %w[occurred_at -occurred_at value -value score -score].each do |sort|
    it "paginates #{sort} across sources, ties and nulls without duplicates or late inserts" do
      known = insider_event(shares: 10, price: 50)
      unknown = insider_event(price: nil)
      institutional_pair
      get api_v1_activity_path, params: { sort:, limit: 1 }
      ids = data.pluck("id")
      cursor = meta.fetch("next_cursor")
      insider_event(transaction_code: "S")
      2.times do
        get api_v1_activity_path, params: { sort:, limit: 1, cursor: }
        expect(response).to have_http_status(:ok)
        expect(meta.fetch("total_count")).to eq(3)
        ids.concat(data.pluck("id"))
        cursor = meta.fetch("next_cursor")
      end
      expect(ids.length).to eq(3)
      expect(ids.uniq.length).to eq(3)
      expect(meta.fetch("has_more")).to be(false)
      institutional = ids.find { |id| id.start_with?("institutional_") }
      known_id, unknown_id = [ known, unknown ].map { |record| "insider_#{record.id}" }
      expected = case sort
      when "occurred_at" then [ institutional, known_id, unknown_id ]
      when "-occurred_at" then [ unknown_id, known_id, institutional ]
      when "value" then [ known_id, institutional, unknown_id ]
      when "-value" then [ institutional, known_id, unknown_id ]
      when "score" then [ known_id, unknown_id, institutional ]
      when "-score" then [ institutional, unknown_id, known_id ]
      end
      expect(ids).to eq(expected)
    end
  end

  it "keeps institutional event versions readable after restatements and preserves insider filing history" do
    transaction = insider_event
    fund, _prior, current = institutional_pair
    get api_v1_activity_path
    institutional = data.find { |row| row["source"] == "institutional" }
    original_id = institutional.fetch("id")
    replacement = create_13f(fund:, filed_at: 1.day.ago, amendment_type: "RESTATEMENT")
    create(:institutional_holding, institutional_report: replacement, shares: 200, value_usd: 2000)
    amendment = create(:filing, form_type: "4/A", filed_at: 1.day.ago, amends_accession_no: transaction.accession_no)
    create(:insider_transaction, filing: amendment)

    get api_v1_activity_event_path(original_id)
    expect(response).to have_http_status(:ok)
    expect(data).to include("id" => original_id, "accession" => current.filing.accession_no)
    expect(data.dig("position_change", "shares_delta")).to eq("50.0")
    get api_v1_activity_event_path("insider_#{transaction.id}")
    expect(data.fetch("accession")).to eq(transaction.accession_no)
    get api_v1_activity_path
    expect(data.pluck("id")).not_to include(original_id, "insider_#{transaction.id}")
  end

  it "does not fabricate scores, sectors or not-yet-ingested filing types" do
    insider_event
    [ { level: "high" }, { min_score: "0" }, { sector: "Technology" }, { source: "13dg" }, { source: "144" } ].each do |values|
      get api_v1_activity_path, params: values
      expect(response).to have_http_status(:ok)
      expect(data).to eq([])
    end
  end

  it "keeps cursor value boundaries exact for large fractional amounts" do
    first = insider_event(shares: BigDecimal("9223372036854775808000.000001"), price: 1)
    second = insider_event(shares: BigDecimal("9223372036854775808000.000002"), price: 1)
    get api_v1_activity_path, params: { sort: "-value", limit: 1 }
    expect(data.pluck("id")).to eq([ "insider_#{second.id}" ])
    cursor = meta.fetch("next_cursor")
    get api_v1_activity_path, params: { sort: "-value", limit: 1, cursor: }
    expect(data.pluck("id")).to eq([ "insider_#{first.id}" ])
    expect(data.first.fetch("value")).to eq("9223372036854775808000.000001")
  end

  it "bounds watchlist cursors to the authenticated owner and the initial memberships" do
    first = insider_event(issuer_ticker: "ALPHA")
    insider_event(issuer_ticker: "BETA")
    insider_event(issuer_ticker: "GAMMA")
    user = create(:user, password: "password123")
    create(:follow, user:, target_type: "Ticker", target_key: "ALPHA")
    create(:follow, user:, target_type: "Ticker", target_key: "BETA")
    api_login(user)
    get api_v1_activity_path, params: { watchlist_only: true, limit: 1 }
    cursor = meta.fetch("next_cursor")
    create(:follow, user:, target_type: "Ticker", target_key: "GAMMA")
    get api_v1_activity_path, params: { watchlist_only: true, limit: 1, cursor: }
    expect(meta.fetch("total_count")).to eq(2)
    expect(data.pluck("id")).to eq([ "insider_#{first.id}" ])

    other = create(:user, email_address: "other@example.com", password: "password123")
    api_login(other)
    get api_v1_activity_path, params: { watchlist_only: true, cursor: }
    expect(response).to have_http_status(:bad_request)
  end

  it "keeps a paginated comparison snapshot intact when an amendment arrives between pages" do
    insider_event
    fund, _prior, current = institutional_pair
    get api_v1_activity_path, params: { limit: 1 }
    cursor = meta.fetch("next_cursor")
    amendment = create_13f(fund:, filed_at: 1.day.ago, amendment_type: "RESTATEMENT")
    create(:institutional_holding, institutional_report: amendment, shares: 200, value_usd: 2000)
    get api_v1_activity_path, params: { limit: 1, cursor: }
    expect(data.sole.fetch("accession")).to eq(current.filing.accession_no)
    expect(data.sole.dig("position_change", "shares_delta")).to eq("50.0")
    expect(meta.fetch("total_count")).to eq(2)
  end

  it "keeps missing normalized values unknown instead of summing a partial total" do
    _fund, prior, current = institutional_pair
    create(:institutional_holding, institutional_report: current, value_usd: nil, shares: 5, suspect: true)
    get api_v1_activity_path
    expect(data.sole.fetch("value")).to be_nil
    expect(data.sole.dig("position_change", "value_usd_after")).to be_nil
    expect(data.sole.dig("position_change", "value_usd_delta")).to be_nil
    expect(data.sole.dig("position_change", "shares_before")).to eq(prior.institutional_holdings.sole.shares.to_s("F"))
  end

  it "hydrates page sources with bounded queries rather than loading each filing per row" do
    6.times { insider_event }
    reads = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      reads << payload[:sql] if payload[:sql].match?(/SELECT "filings"\.\*/)
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { get api_v1_activity_path }
    expect(data.length).to eq(6)
    expect(reads.length).to eq(1)
  end

  it "preserves distinct option positions when classifying institutional changes" do
    _fund, prior, current = institutional_pair
    create(:institutional_holding, institutional_report: prior, put_call: "CALL", shares: 50, value_usd: 500)
    create(:institutional_holding, institutional_report: current, put_call: "CALL", shares: 25, value_usd: 250)
    create(:institutional_holding, institutional_report: prior, cusip: "594918104", shares: 100, value_usd: 1000)
    create(:institutional_holding, institutional_report: current, cusip: "02079K305", shares: 200, value_usd: 2000)
    get api_v1_activity_path
    expect(data.map { |event| event.dig("position_change", "change_type") }).to contain_exactly("added", "reduced", "exited", "new")
    expect(data.pluck("id").uniq.length).to eq(4)
    expect(data.pluck("direction").uniq).to contain_exactly("increase", "decrease")
    expect(data.map { |event| event.dig("position_change", "put_call") }).to include("CALL", nil)
  end

  it "keeps derivative and non-derivative transaction lines separate even when sequences match" do
    canonical = insider_event(txn_seq: 1)
    derivative = create(:insider_transaction, filing: canonical.filing, txn_seq: 1, security_table: "derivative")
    create(:insider_transaction, filing: canonical.filing, txn_seq: 1, owner_seq: 2, insider_cik: "0000000789")
    get api_v1_activity_path
    expect(data.pluck("id")).to contain_exactly("insider_#{canonical.id}", "insider_#{derivative.id}")
    expect(data.find { |event| event["id"] == "insider_#{canonical.id}" }.fetch("reporting_owners").length).to eq(2)
    expect(data.find { |event| event["id"] == "insider_#{derivative.id}" }.fetch("reporting_owners").length).to eq(1)
  end

  it "does not expose failed, pending, undated or future insider filings through lists or direct event links" do
    [ { parse_status: "failed" }, { parse_status: "pending" }, { filed_at: nil }, { filed_at: 1.day.from_now } ].each do |attributes|
      transaction = create(:insider_transaction, filing: create(:filing, **attributes))
      get api_v1_activity_event_path("insider_#{transaction.id}")
      expect(response).to have_http_status(:not_found)
    end
    get api_v1_activity_path
    expect(data).to eq([])
  end

  it "rejects an expired feed cursor" do
    2.times { insider_event }
    get api_v1_activity_path, params: { limit: 1 }
    cursor = meta.fetch("next_cursor")
    travel 25.hours
    get api_v1_activity_path, params: { cursor: }
    expect(response).to have_http_status(:bad_request)
  end

  it "rejects invalid filters, altered cursors, unknown events and altered institutional versions" do
    insider_event
    institutional_pair
    get api_v1_activity_path, params: { limit: 1 }
    cursor = meta.fetch("next_cursor")
    [ { source: "unknown" }, { direction: "invalid" }, { min_value: "NaN" }, { min_score: "101" }, { min_score: "1.5" },
      { date_from: "2026-02-30" }, { date_from: "2026-11-10", date_to: "2026-11-09" }, { watchlist_only: "yes" },
      { sort: "occurred_at; SELECT 1" }, { level: "unknown" }, { sector: "a" * 81 }, { source: [ "insider" ] },
      { cursor: "#{cursor}x" }, { cursor:, source: "insider" } ].each do |values|
      get api_v1_activity_path, params: values
      expect(response).to have_http_status(:bad_request), values.inspect
    end
    get api_v1_activity_path, params: { source: "institutional" }
    event_id = data.sole.fetch("id")
    [ "#{event_id}x", "insider_999999999", "invalid", "institutional_invalid" ].each do |id|
      get api_v1_activity_event_path(id)
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("NOT_FOUND")
    end
  end
end
