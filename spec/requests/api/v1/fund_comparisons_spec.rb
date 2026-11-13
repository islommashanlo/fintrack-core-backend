# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 fund comparison" do
  include InstitutionalReadHelpers
  include ApiAccounts
  include OpenapiResponses
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }
  let(:first) { create(:institutional_filer, name: "First Example Fund") }
  let(:second) { create(:institutional_filer, name: "Second Example Fund") }
  let(:period) { Date.new(2026, 9, 30) }
  let(:prior) { Date.new(2026, 6, 30) }

  def data = response.parsed_body.fetch("data")
  def meta = response.parsed_body.fetch("meta")
  def compare(funds = [ first, second ], **values)
    get api_v1_fund_comparison_path, params: { ciks: funds.map(&:cik).join(","), **values }
    expect_documented_response(path: "/funds/compare") if response.successful?
  end

  def report(fund, quarter = period, **values)
    create_13f(fund:, period: quarter, filed_at: quarter == period ? 2.days.ago : Time.utc(2026, 8, 14), **values)
  end

  def holding(report, shares: 100, **values)
    create(:institutional_holding, institutional_report: report, shares:, value_usd: shares * 10, **values)
  end

  def pair(fund, before: 100, after: 150, **values)
    previous, current = report(fund, prior), report(fund)
    holding(previous, shares: before, **values) if before
    holding(current, shares: after, **values) if after
    [ previous, current ]
  end

  it "compares the same quarter, reports overlap and differing moves with all source evidence" do
    first_prior, first_current = pair(first)
    second_prior, second_current = pair(second, before: 100, after: 50)
    compare
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(meta).to include("period_of_report" => period.iso8601, "prior_period_of_report" => prior.iso8601,
      "period_selection" => "latest_common", "complete" => true, "prior_complete" => true, "total_count" => 1)
    expect(data.fetch("overlaps").sole).to include("complete" => true, "shared_position_count" => 1,
      "union_position_count" => 1, "overlap_percent" => "100.0", "differing_move_count" => 1)
    row = data.fetch("positions").sole
    expect(row).to include("cusip" => "037833100", "holder_count" => 2, "shared_by_all" => true, "differing_moves" => true)
    expect(row.fetch("funds").pluck("change_type")).to eq(%w[added reduced])
    expect(row.fetch("funds").pluck("shares_delta")).to eq([ "50.0", "-50.0" ])
    expect(row.fetch("funds").pluck("value_usd_delta")).to eq([ "500.0", "-500.0" ])
    sources = row.fetch("funds").flat_map { |entry| entry.fetch("current_sources") + entry.fetch("prior_sources") }
    expect(sources.pluck("accession")).to contain_exactly(*[ first_prior, first_current, second_prior, second_current ].map { |r| r.filing.accession_no })
    expect(row.fetch("funds")).to all(include("accession", "sec_url", "filed_at", "ingested_at", "data_age_days"))
    expect(meta.fetch("disclaimer")).to eq(FilingsIntel::DISCLAIMER)
  end

  it "counts union/intersection keys in SQL and keeps options and principal separate" do
    a, b = report(first), report(second)
    holding(a)
    holding(a, put_call: "PUT")
    holding(a, put_call: "CALL")
    holding(a, share_type: "PRN")
    holding(b)
    holding(b, cusip: "594918104")
    compare
    expect(data.fetch("overlaps").sole).to include("shared_position_count" => 1, "union_position_count" => 5,
      "overlap_percent" => "20.0", "differing_move_count" => nil)
    expect(data.fetch("positions").length).to eq(5)
    compare(scope: "shared")
    expect(data.fetch("positions").sole).to include("put_call" => nil, "share_type" => "SH", "holder_count" => 2)
    compare(put_call: "PUT")
    expect(data.fetch("positions").sole.fetch("put_call")).to eq("PUT")
  end

  it "aggregates repeated rows, restatements and later additions without counting superseded holdings" do
    previous = report(first, prior)
    holding(previous, shares: 100)
    original = report(first)
    holding(original, shares: 9999)
    replacement = report(first, amendment_type: "RESTATEMENT", filed_at: 1.day.ago)
    holding(replacement, shares: 70)
    holding(replacement, shares: 30)
    addition = report(first, amendment_type: "NEW HOLDINGS", filed_at: 1.hour.ago)
    holding(addition, shares: 25)
    pair(second, after: 100)
    compare
    entry = data.fetch("positions").sole.fetch("funds").first
    expect(entry).to include("shares" => "125.0", "row_count" => 3, "shares_delta" => "25.0", "change_type" => "added")
    expect(entry.fetch("current_sources").pluck("accession")).to contain_exactly(replacement.filing.accession_no, addition.filing.accession_no)
    expect(entry.fetch("current_sources").pluck("accession")).not_to include(original.filing.accession_no)
    expect(original.institutional_holdings.sole.shares).to eq(9999.to_d)
  end

  it "uses the latest common quarter rather than mixing funds' latest quarters" do
    shared_a = report(first, prior)
    shared_b = report(second, prior)
    holding(shared_a)
    holding(shared_b)
    holding(report(first), shares: 500)
    compare
    expect(meta.fetch("period_of_report")).to eq(prior.iso8601)
    expect(data.fetch("positions").sole.fetch("funds").pluck("shares")).to eq([ "100.0", "100.0" ])
  end

  it "keeps missing reports unknown and distinguishes a known empty portfolio" do
    holding(report(first))
    compare(period: period.iso8601)
    expect(meta.fetch("complete")).to be(false)
    expect(data.fetch("overlaps").sole).to include("complete" => false, "shared_position_count" => nil, "overlap_percent" => nil)
    entry = data.fetch("positions").sole.fetch("funds").last
    expect(entry).to include("present" => nil, "shares" => nil, "change_type" => "unknown", "current_available" => false)
    expect(data.fetch("funds").last.fetch("position_count")).to be_nil
    report(second)
    compare(period: period.iso8601)
    expect(meta.fetch("complete")).to be(true)
    expect(data.fetch("overlaps").sole).to include("shared_position_count" => 0, "union_position_count" => 1, "overlap_percent" => "0.0")
    expect(data.fetch("positions").sole.fetch("funds").last.fetch("present")).to be(false)
    expect(data.fetch("funds").last.fetch("position_count")).to eq(0)
  end

  it "returns unavailable with no common period and treats notices or orphan additions as missing holdings" do
    holding(report(first))
    report(second, submission_type: "13F-NT", report_type: "13F NOTICE")
    orphan = report(second, amendment_type: "NEW HOLDINGS")
    holding(orphan)
    compare
    expect(meta).to include("available" => false, "unavailable_reason" => "no_common_period", "period_of_report" => nil)
    expect(data.fetch("positions")).to eq([])
    compare(period: period.iso8601)
    expect(data.fetch("funds").last.fetch("current_report_present")).to be(false)
    expect(data.fetch("positions").sole.fetch("shared_by_all")).to be_nil
  end

  it "derives exits, new and unchanged positions only from an adjacent valid baseline" do
    old_a, current_a = pair(first, before: 100, after: nil)
    old_b, current_b = pair(second, before: nil, after: 50)
    compare(scope: "differing_moves")
    entries = data.fetch("positions").sole.fetch("funds")
    expect(entries.pluck("change_type")).to eq(%w[exited new])
    expect(entries.pluck("shares_delta")).to eq([ "-100.0", "50.0" ])
    holding(current_a, shares: 100)
    holding(old_b, shares: 50)
    compare
    expect(data.fetch("positions").sole.fetch("funds").pluck("change_type")).to eq(%w[unchanged unchanged])
    expect(data.fetch("positions").sole.fetch("differing_moves")).to be(false)
    old_a.update!(period_of_report: Date.new(2026, 3, 31))
    compare
    expect(data.fetch("positions").sole.fetch("funds").first.fetch("change_type")).to eq("unknown")
  end

  it "retains suspect reported totals and marks derived changes unknown without correcting stored values" do
    pair(first)
    _previous, current = pair(second)
    row = current.institutional_holdings.sole
    row.update!(suspect: true, value_usd: nil)
    compare
    entry = data.fetch("positions").sole.fetch("funds").last
    expect(entry).to include("suspect" => true, "shares" => "150.0", "value_usd" => nil,
      "shares_delta" => nil, "value_usd_delta" => nil, "change_type" => "unknown")
    expect(data.fetch("positions").sole.fetch("differing_moves")).to be_nil
    expect(row.reload.value_reported).to eq(100.to_d)
    expect(data.fetch("overlaps").sole.fetch("differing_move_count")).to be_nil
  end

  it "reports excluded malformed keys and report anomalies rather than inferring complete absence" do
    a, b = report(first), report(second)
    holding(a)
    holding(b, cusip: "BAD")
    compare
    expect(data.fetch("funds").last).to include("current_report_present" => true, "current_available" => false, "excluded_current_rows" => 1)
    expect(data.fetch("positions").sole.fetch("funds").last.fetch("present")).to be_nil
    a.update!(suspect: true, suspect_reason: "entry_count_mismatch")
    compare
    expect(data.fetch("funds").first).to include("current_report_suspect" => true, "current_available" => false)
    expect(data.fetch("overlaps").sole.fetch("overlap_percent")).to be_nil
  end

  it "does not let failed or future amendments supersede known holdings" do
    pair(first)
    pair(second)
    holding(report(first, amendment_type: "RESTATEMENT", status: "failed"), shares: 9999)
    holding(report(second, amendment_type: "RESTATEMENT", filed_at: 1.day.from_now), shares: 8888)
    compare
    expect(data.fetch("positions").sole.fetch("funds").pluck("shares")).to eq([ "150.0", "150.0" ])
  end

  it "attributes recomputed changes to a later amendment of the prior quarter" do
    pair(first)
    pair(second)
    restatement = report(first, prior, amendment_type: "RESTATEMENT", filed_at: 1.hour.ago)
    holding(restatement, shares: 200)
    compare
    row = data.fetch("positions").sole
    expect(row).to include("accession" => restatement.filing.accession_no, "data_age_days" => 0)
    expect(row.fetch("funds").first).to include("change_type" => "reduced", "prior_shares" => "200.0", "shares_delta" => "-50.0")
    expect(row.fetch("funds").first.fetch("prior_sources").pluck("accession")).to eq([ restatement.filing.accession_no ])
  end

  it "enforces Free fund/history limits and allows verified Pro comparisons, including downgrade checks on cursors" do
    with_billing_config do
      third = create(:institutional_filer)
      [ first, second, third ].each { |f| pair(f) }
      compare([ first, second, third ])
      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body).to eq("code" => "PRO_REQUIRED", "feature" => "fund_compare", "limit" => 2)
      compare(period: "2020-03-31")
      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body.fetch("feature")).to eq("history_quarters")
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      holding(first.institutional_reports.find_by!(period_of_report: period), cusip: "594918104")
      compare([ first, second, third ], limit: "1")
      expect(response).to have_http_status(:ok)
      expect(data.fetch("funds").length).to eq(3)
      cursor = meta.fetch("next_cursor")
      apply_billing_event(id: "evt_compare_canceled", snapshot: billing_snapshot(status: "canceled"), type: "customer.subscription.deleted")
      compare([ first, second, third ], cursor:, limit: "1")
      expect(response).to have_http_status(:payment_required)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  it "pins the default period and ingestion ceilings while paging and rejects foreign filters" do
    a, b = report(first, prior), report(second, prior)
    %w[037833100 594918104 023135106].each { |cusip| holding(a, cusip:); holding(b, cusip:) }
    pending = [ first, second ].map { |f| report(f, status: "pending") }
    pending.each { |r| holding(r, cusip: "999999999") }
    compare(limit: "1", sort: "cusip")
    seen = data.fetch("positions").map { |r| r.fetch("cusip") }
    cursor = meta.fetch("next_cursor")
    pending.each { |r| r.update!(status: "parsed") }
    holding(a, cusip: "111111111")
    while cursor
      compare(limit: "1", sort: "cusip", cursor:)
      expect(response).to have_http_status(:ok)
      expect(meta.fetch("period_of_report")).to eq(prior.iso8601)
      seen += data.fetch("positions").map { |r| r.fetch("cusip") }
      cursor = meta.fetch("next_cursor")
    end
    expect(seen).to eq(%w[023135106 037833100 594918104])
    compare(limit: "1")
    # The latest quarter has only one key; obtain a multi-key cursor explicitly.
    compare(period: prior.iso8601, limit: "1")
    cursor = meta.fetch("next_cursor")
    compare(period: prior.iso8601, scope: "shared", limit: "1", cursor:)
    expect(response).to have_http_status(:bad_request)
  end

  it "returns unavailable for an explicit period without reports and batches provenance as positions grow" do
    pair(first)
    pair(second)
    compare(period: "2026-12-31")
    expect(meta).to include("available" => false, "unavailable_reason" => "no_current_reports", "complete" => false)
    measure = lambda do
      queries = []
      callback = lambda { |*args| queries << args.last[:sql] unless args.last[:name] == "SCHEMA" || args.last[:cached] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { compare(limit: "25") }
      expect(response).to have_http_status(:ok)
      queries.grep(/\ASELECT|\AWITH/).length
    end
    baseline = measure.call
    8.times do |index|
      [ first, second ].each do |f|
        holding(f.institutional_reports.find_by!(period_of_report: period), cusip: format("%09d", 100 + index))
      end
    end
    expect(measure.call).to be <= baseline + 1
    expect(data.fetch("positions").length).to eq(9)
  end

  it "handles empty books, duplicate CIK input, unknown funds and strict parameters" do
    report(first)
    report(second)
    get api_v1_fund_comparison_path, params: { ciks: "#{second.cik},#{first.cik},#{first.cik}" }
    expect(response).to have_http_status(:ok)
    expect(data.fetch("funds").length).to eq(2)
    expect(data.fetch("overlaps").sole).to include("shared_position_count" => 0, "union_position_count" => 0, "overlap_percent" => nil)
    expect(WebMock).not_to have_requested(:any, /./)
    [ { ciks: first.cik }, { ciks: [ first.cik, second.cik ] }, { ciks: "1,2" }, { ciks: "#{first.cik}," },
      { period: "2026-09-29" }, { scope: "recommended" }, { put_call: "ANY" }, { sort: "score;DROP" },
      { limit: "0" }, { user_id: "1" }, { cursor: "tampered" } ].each do |values|
      compare(**values)
      expect(response).to have_http_status(:bad_request)
    end
    get api_v1_fund_comparison_path, params: { ciks: "#{first.cik},0000000001" }
    expect(response).to have_http_status(:not_found)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end
end
