# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Fund change portfolio analytics" do
  include OpenapiResponses
  include InstitutionalReadHelpers
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }
  let(:fund) { create(:institutional_filer) }
  let(:older) { Date.new(2026, 3, 31) }
  let(:current) { Date.new(2026, 6, 30) }

  def report(period: current, rows: [ {} ], **attributes)
    item = create_13f(fund:, period:, **attributes)
    holdings = rows.map do |row|
      value = row.fetch(:value_reported, 100)
      create(:institutional_holding, institutional_report: item, value_reported: value, value_usd: value, **row)
    end
    item.update!(table_entry_total: holdings.length, table_value_total: holdings.sum(&:value_reported))
    item
  end

  def fetch(**parameters)
    get changes_api_v1_fund_path(fund.cik), params: parameters
    expect_documented_response(path: "/funds/{cik}/changes")
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def weight(position)
    BigDecimal(position.fetch("weight_percent"))
  end

  it "uses full portfolios including unchanged positions, before applying change filters" do
    previous = report(period: older, rows: [ { shares: 10 }, { cusip: "594918104", value_reported: 300 } ])
    latest = report(rows: [ { shares: 20, value_reported: 200 }, { cusip: "594918104", value_reported: 300 } ])
    body = fetch(change_type: "added")
    expect(body.fetch("data").size).to eq(1)
    row = body.fetch("data").first
    expect(row).to include("change_type" => "added", "shares_before" => "10.0", "shares_after" => "20.0")
    expect(row.fetch("current_position")).to include("value_usd" => "200.0", "rank" => 2)
    expect(row.fetch("prior_position")).to include("value_usd" => "100.0", "rank" => 2)
    expect(weight(row.fetch("current_position"))).to eq(40)
    expect(weight(row.fetch("prior_position"))).to eq(25)
    expect(body.fetch("meta")).to include("period_of_report" => current.iso8601, "prior_period_of_report" => older.iso8601)
    expect(body.dig("meta", "current_portfolio")).to include("complete" => true, "report_ids" => [ latest.id ], "position_count" => 2)
    expect(body.dig("meta", "prior_portfolio")).to include("complete" => true, "report_ids" => [ previous.id ])
  end

  it "separates new and exited positions from unknown portfolio coverage" do
    report(period: older, rows: [ {} ])
    report(rows: [ { cusip: "594918104" } ])
    rows = fetch.fetch("data").index_by { |row| row.fetch("change_type") }
    expect(rows.fetch("new").fetch("prior_position")).to be_nil
    expect(rows.fetch("exited").fetch("current_position")).to be_nil
    expect(rows.fetch("new").fetch("current_position")).to include("rank" => 1)
    expect(weight(rows.fetch("exited").fetch("prior_position"))).to eq(100)
  end

  it "does not invent a prior portfolio for the first observed period" do
    report
    body = fetch
    expect(body.fetch("data").first).to include("change_type" => "new", "prior_position" => nil, "prior_period_of_report" => nil)
    expect(body.dig("meta", "prior_period_of_report")).to be_nil
    expect(body.dig("meta", "prior_portfolio")).to include("complete" => false, "total_value_usd" => nil, "report_ids" => [])
  end

  it "uses the preceding available holdings period across gaps and skips notices and unresolved additions" do
    report(period: older)
    report(period: Date.new(2026, 6, 30), submission_type: "13F-NT", report_type: "13F NOTICE", rows: [])
    report(period: Date.new(2026, 6, 30), amendment_type: "NEW HOLDINGS")
    report(period: Date.new(2026, 9, 30), rows: [ { shares: 20 } ])
    body = fetch
    expect(body.dig("meta", "prior_period_of_report")).to eq(older.iso8601)
    expect(body.dig("data", 0, "prior_period_of_report")).to eq(older.iso8601)
    expect(body.dig("meta", "prior_portfolio", "complete")).to be(true)
  end

  it "suppresses only the incomplete side even when the invalid position is not in the changes" do
    report(period: older, rows: [ {}, { cusip: "594918104", value_usd: nil } ])
    report(rows: [ { shares: 20 }, { cusip: "594918104" } ])
    body = fetch(change_type: "added")
    expect(body.dig("meta", "prior_portfolio", "complete")).to be(false)
    expect(body.dig("meta", "current_portfolio", "complete")).to be(true)
    expect(body.dig("data", 0, "prior_position")).to include("value_usd" => "100.0", "rank" => nil, "weight_percent" => nil)
    expect(body.dig("data", 0, "current_position", "rank")).to eq(1)
  end

  it "resolves both amendment types and groups repeated keys across reports, keeping options separate" do
    report(period: older)
    report
    replacement = report(amendment_type: "RESTATEMENT", filed_at: Time.utc(2026, 8, 15),
      rows: [ { shares: 20 }, { put_call: "PUT", shares: 5, value_reported: 50 } ])
    addition = report(amendment_type: "NEW HOLDINGS", filed_at: Time.utc(2026, 8, 16),
      rows: [ { shares: 10, value_reported: 50 }, { share_type: "PRN", value_reported: 100 } ])
    body = fetch
    common = body.fetch("data").find { |row| row["put_call"].nil? && row["share_type"] == "SH" }
    expect(common.fetch("current_position")).to include("row_count" => 2, "value_usd" => "150.0", "rank" => 1)
    expect(weight(common.fetch("current_position"))).to eq(50)
    expect(body.dig("meta", "current_portfolio")).to include("report_ids" => [ replacement.id, addition.id ], "position_count" => 3)
  end

  it "pins denominators, comparison periods and report sets through pagination and later ingestion" do
    previous = report(period: older, rows: [ {}, { cusip: "594918104", value_reported: 300 } ])
    latest = report(rows: [ { shares: 20, value_reported: 200 }, { cusip: "594918104", shares: 20, value_reported: 300 } ])
    first = fetch(limit: 1, sort: "cusip")
    report(period: older, filed_at: Time.current, amendment_type: "RESTATEMENT", rows: [ { value_reported: 999 } ])
    report(filed_at: Time.current, amendment_type: "NEW HOLDINGS")
    report(period: Date.new(2026, 9, 30))
    create(:institutional_holding, institutional_report: latest, value_reported: 999)
    second = fetch(limit: 1, sort: "cusip", cursor: first.dig("meta", "next_cursor"))
    expect(second.dig("meta", "current_portfolio")).to eq(first.dig("meta", "current_portfolio"))
    expect(second.dig("meta", "prior_portfolio")).to eq(first.dig("meta", "prior_portfolio"))
    expect(second.dig("meta", "prior_portfolio", "report_ids")).to eq([ previous.id ])
    expect(second.dig("meta", "period_of_report")).to eq(current.iso8601)
    row = second.fetch("data").first
    expect(weight(row.fetch("current_position"))).to eq(60)
    expect(weight(row.fetch("prior_position"))).to eq(75)
  end

  it "reports comparison coverage even when there are no changed positions" do
    report(period: older)
    report
    body = fetch
    expect(body.fetch("data")).to eq([])
    expect(body.dig("meta", "current_portfolio")).to include("complete" => true, "position_count" => 1)
    expect(body.dig("meta", "prior_portfolio", "complete")).to be(true)
  end

  it "retains known zero ranks and unknown zero-denominator weights" do
    report(period: older, rows: [ { value_reported: 0 } ])
    report(rows: [ { shares: 20, value_reported: 0 } ])
    row = fetch.fetch("data").first
    %w[current_position prior_position].each do |key|
      expect(row.fetch(key)).to include("value_usd" => "0.0", "rank" => 1, "weight_percent" => nil)
    end
  end

  it "returns empty coverage without reports and preserves history gates without external requests" do
    body = fetch
    expect(body.fetch("data")).to eq([])
    expect(body.dig("meta", "current_portfolio")).to include("complete" => false, "report_count" => 0)
    report(period: Date.new(2024, 12, 31))
    get changes_api_v1_fund_path(fund.cik), params: { period: "2024-12-31" }
    expect_documented_response(path: "/funds/{cik}/changes")
    expect(response).to have_http_status(:payment_required)
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
